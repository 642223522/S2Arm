// s2a-selfsign：电脑上给游戏程序库（arm64 单架构 Mach-O dylib）签 Apple 代码签名，原地写回。
//   s2a-selfsign --key key.pem --cert cert.der --bundle-id <App 包名> --team <团队号> <dylib>
//   退出码 0 = 签好；失败打一行原因（stderr）、退出码 1；参数不对退出码 2。
// 签法逐段照手机端 runtime/src/selfsign.c（免费团队真机验过，cmdr 免费团队手机自签定稿）：
//   SuperBlob 0xfade0cc0 = CodeDirectory（v0x20400，SHA-256，16 KiB 页）+ 空 Requirements + XML 权限（-5）+ DER 权限（-7）+ CMS（BlobWrapper）。
//   签名标识 = 包名（免费团队按描述文件校验：「团队号.签名标识」要等于 application-identifier）；
//   权限只放 application-identifier（团队号.包名）与 com.apple.developer.team-identifier（团队号）；
//   CMS = PKCS#7 SignedData 分离式，签 CodeDirectory：签名属性 contentType / signingTime / messageDigest / Apple cdhashes2 / cdhashes（plist）；
//   证书 = 叶证书 + WWDR G3 + Apple Root（系统 codesign 对 dylib 不放权限槽，免费团队认不了，所以自己签）。RSA PKCS#1 v1.5 + SHA-256。
//   输入可以已有签名（ad-hoc 或别的证书）：在原 LC_CODE_SIGNATURE 处截断、按新签名大小改该命令与 __LINKEDIT 尺寸后重写，代码页本身不动。
// 单测：S2A_SELFSIGN_TIME=<yymmddhhmmssZ> 固定签名时间、S2A_SELFSIGN_NOCHAIN=1 只带叶证书（与手机端签法逐字节比用），玩家路径不设。
use ring::digest::{SHA256, digest};
use ring::rand::SystemRandom;
use ring::signature::{RSA_PKCS1_SHA256, RsaKeyPair};
use std::time::{SystemTime, UNIX_EPOCH};

mod certs;
const WWDR_G3: &[u8] = &certs::WWDR_G3;
const APPLE_ROOT: &[u8] = &certs::APPLE_ROOT;

const MH_MAGIC_64: u32 = 0xfeedfacf;
const MH_EXECUTE: u32 = 0x2;
const CPU_TYPE_ARM64: u32 = 0x0100000c;
const LC_SEGMENT_64: u32 = 0x19;
const LC_CODE_SIGNATURE: u32 = 0x1d;
const PAGE_SHIFT: u32 = 14;
const PAGE: u32 = 1 << PAGE_SHIFT;

const OID_DATA: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x01];
const OID_SIGNED_DATA: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02];
const OID_SHA256: &[u8] = &[0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01];
const OID_RSA: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01];
const OID_CONTENT_TYPE: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x03];
const OID_MESSAGE_DIGEST: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x04];
const OID_SIGNING_TIME: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x05];
const OID_APPLE_CDHASHES: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x09, 0x01];
const OID_APPLE_CDHASHES2: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x09, 0x02];

fn sha256(d: &[u8]) -> [u8; 32] {
    let mut o = [0u8; 32];
    o.copy_from_slice(digest(&SHA256, d).as_ref());
    o
}
fn be32(v: u32) -> [u8; 4] { v.to_be_bytes() }
fn rd32le(b: &[u8], o: usize) -> u32 { u32::from_le_bytes(b[o..o + 4].try_into().unwrap()) }
fn rd64le(b: &[u8], o: usize) -> u64 { u64::from_le_bytes(b[o..o + 8].try_into().unwrap()) }

// ---------- DER ----------
fn der_len(out: &mut Vec<u8>, n: usize) {
    if n < 0x80 { out.push(n as u8) }
    else if n < 0x100 { out.extend([0x81, n as u8]) }
    else if n < 0x10000 { out.extend([0x82, (n >> 8) as u8, n as u8]) }
    else { out.extend([0x83, (n >> 16) as u8, (n >> 8) as u8, n as u8]) }
}
fn tlv(tag: u8, v: &[u8]) -> Vec<u8> {
    let mut o = vec![tag];
    der_len(&mut o, v.len());
    o.extend_from_slice(v);
    o
}
fn oid(o: &[u8]) -> Vec<u8> { tlv(0x06, o) }
fn alg_sha256() -> Vec<u8> { tlv(0x30, &[oid(OID_SHA256), tlv(0x05, &[])].concat()) }
// 读一个 TLV：(tag, 内容, 这个 TLV 之后)
fn der_read(p: &[u8]) -> Option<(u8, &[u8], &[u8])> {
    if p.len() < 2 { return None }
    let tag = p[0];
    let mut l = p[1] as usize;
    let mut q = 2;
    if l & 0x80 != 0 {
        let k = l & 0x7f;
        if !(1..=3).contains(&k) || p.len() < 2 + k { return None }
        l = 0;
        for i in 0..k { l = l << 8 | p[2 + i] as usize }
        q += k;
    }
    if p.len() < q + l { return None }
    Some((tag, &p[q..q + l], &p[q + l..]))
}
// 叶证书里取 issuer 与 serial 原样 TLV（SignerInfo 的 issuerAndSerialNumber）
fn cert_issuer_serial(der: &[u8]) -> Option<Vec<u8>> {
    let (t, cert, _) = der_read(der)?;
    if t != 0x30 { return None }
    let (t, tbs, _) = der_read(cert)?;
    if t != 0x30 { return None }
    let mut p = tbs;
    if p.first() == Some(&0xa0) { p = der_read(p)?.2 }
    let serial_start = p;
    let (t, _, rest) = der_read(p)?;
    if t != 0x02 { return None }
    let serial = &serial_start[..serial_start.len() - rest.len()];
    let (t, _, rest) = der_read(rest)?;
    if t != 0x30 { return None }
    let issuer_start = rest;
    let (t, _, after) = der_read(rest)?;
    if t != 0x30 { return None }
    let issuer = &issuer_start[..issuer_start.len() - after.len()];
    Some(tlv(0x30, &[issuer, serial].concat()))
}

// ---------- 时间（UTCTime yymmddhhmmssZ）----------
fn utc_now() -> String {
    if let Ok(t) = std::env::var("S2A_SELFSIGN_TIME") { return t }
    let s = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0) as i64;
    let (days, sec) = (s.div_euclid(86400), s.rem_euclid(86400));
    // 民用历（Howard Hinnant days_from_civil 的逆）
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + if m <= 2 { 1 } else { 0 };
    format!("{:02}{:02}{:02}{:02}{:02}{:02}Z", y % 100, m, d, sec / 3600, sec / 60 % 60, sec % 60)
}

// ---------- CodeDirectory ----------
#[allow(clippy::too_many_arguments)]
fn build_cd(code: &[u8], limit: u32, ident: &str, team: &str, req_hash: &[u8; 32], ent_hash: &[u8; 32], ent_der_hash: &[u8; 32], exec_base: u64, exec_limit: u64, exec_flags: u64) -> Vec<u8> {
    let nslots = limit.div_ceil(PAGE);
    let nspecial: u32 = 7;
    let hdr = 88usize;
    let ident_n = ident.len() + 1;
    let team_n = team.len() + 1;
    let ident_off = hdr;
    let team_off = ident_off + ident_n;
    let hash_off = hdr + ident_n + team_n + nspecial as usize * 32;
    let total = hash_off + nslots as usize * 32;
    let mut h = vec![0u8; total];
    let put = |h: &mut Vec<u8>, o: usize, b: &[u8]| h[o..o + b.len()].copy_from_slice(b);
    put(&mut h, 0, &be32(0xfade0c02)); put(&mut h, 4, &be32(total as u32)); put(&mut h, 8, &be32(0x20400)); put(&mut h, 12, &be32(0));
    put(&mut h, 16, &be32(hash_off as u32)); put(&mut h, 20, &be32(ident_off as u32)); put(&mut h, 24, &be32(nspecial)); put(&mut h, 28, &be32(nslots));
    put(&mut h, 32, &be32(limit)); h[36] = 32; h[37] = 2; h[38] = 0; h[39] = PAGE_SHIFT as u8;
    put(&mut h, 48, &be32(team_off as u32));
    put(&mut h, 64, &exec_base.to_be_bytes()); put(&mut h, 72, &exec_limit.to_be_bytes()); put(&mut h, 80, &exec_flags.to_be_bytes());
    put(&mut h, ident_off, ident.as_bytes());
    put(&mut h, team_off, team.as_bytes());
    put(&mut h, hash_off - 2 * 32, req_hash);   // -2 Requirements（-1 Info.plist 没有，全零）
    put(&mut h, hash_off - 5 * 32, ent_hash);   // -5 XML 权限
    put(&mut h, hash_off - 7 * 32, ent_der_hash);   // -7 DER 权限（-3 / -4 / -6 没有，全零）
    for i in 0..nslots {
        let off = (i << PAGE_SHIFT) as usize;
        let len = (limit as usize - off).min(PAGE as usize);
        put(&mut h, hash_off + i as usize * 32, &sha256(&code[off..off + len]));
    }
    h
}

// ---------- CMS ----------
fn signed_attrs(cd_sha256: &[u8; 32], ts: &str) -> Vec<u8> {
    let attr = |o: &[u8], v: Vec<u8>| tlv(0x30, &[oid(o), tlv(0x31, &v)].concat());
    let mut all = Vec::new();
    all.extend(attr(OID_CONTENT_TYPE, oid(OID_DATA)));
    all.extend(attr(OID_SIGNING_TIME, tlv(0x17, ts.as_bytes())));
    all.extend(attr(OID_MESSAGE_DIGEST, tlv(0x04, cd_sha256)));
    all.extend(attr(OID_APPLE_CDHASHES2, tlv(0x30, &[oid(OID_SHA256), tlv(0x04, cd_sha256)].concat())));
    const HEAD: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n\t<key>cdhashes</key>\n\t<array>\n\t\t<data>\n\t\t";
    const TAIL: &str = "\n\t\t</data>\n\t</array>\n</dict>\n</plist>\n";
    let pl = [HEAD.as_bytes(), b64(&cd_sha256[..20]).as_bytes(), TAIL.as_bytes()].concat();
    all.extend(attr(OID_APPLE_CDHASHES, tlv(0x04, &pl)));
    tlv(0x31, &all)   // DER SET OF 按编码升序：五条长度字节递增，上面的次序就是这个（同 selfsign.c）
}
fn b64(d: &[u8]) -> String {
    const T: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut s = String::new();
    for c in d.chunks(3) {
        let v = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
        s.push(T[(v >> 18 & 63) as usize] as char);
        s.push(T[(v >> 12 & 63) as usize] as char);
        s.push(if c.len() > 1 { T[(v >> 6 & 63) as usize] as char } else { '=' });
        s.push(if c.len() > 2 { T[(v & 63) as usize] as char } else { '=' });
    }
    s
}
fn build_cms(cd_sha256: &[u8; 32], key: &RsaKeyPair, leaf: &[u8], ts: &str) -> Result<Vec<u8>, String> {
    let attrs = signed_attrs(cd_sha256, ts);
    let mut sig = vec![0u8; key.public().modulus_len()];
    key.sign(&RSA_PKCS1_SHA256, &SystemRandom::new(), &attrs, &mut sig).map_err(|_| "私钥签不了（RSA 签名失败）".to_string())?;
    let issuer_serial = cert_issuer_serial(leaf).ok_or("叶证书解析不了（取不到 issuer / serial）")?;
    let mut signed = attrs.clone();
    signed[0] = 0xa0;   // signedAttrs 写成 [0] IMPLICIT（签名时按 SET 0x31 算）
    let si = tlv(0x30, &[tlv(0x02, &[1]), issuer_serial, alg_sha256(), signed, tlv(0x30, &[oid(OID_RSA), tlv(0x05, &[])].concat()), tlv(0x04, &sig)].concat());
    // 单测：S2A_SELFSIGN_NOCHAIN=1 只带叶证书（同手机端单测给的 p12 只有叶证书时），两边预留大小才一样、CodeDirectory 才能逐字节比；玩家路径不设
    let chain = if std::env::var("S2A_SELFSIGN_NOCHAIN").is_ok_and(|v| v == "1") { leaf.to_vec() } else { [leaf, WWDR_G3, APPLE_ROOT].concat() };
    let sd = [tlv(0x02, &[1]), tlv(0x31, &alg_sha256()), tlv(0x30, &oid(OID_DATA)), tlv(0xa0, &chain), tlv(0x31, &si)].concat();
    Ok(tlv(0x30, &[oid(OID_SIGNED_DATA), tlv(0xa0, &tlv(0x30, &sd))].concat()))
}

// ---------- 权限 ----------
fn build_ents(appid: &str, team: &str) -> (Vec<u8>, Vec<u8>) {
    const HEAD: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n";
    let body = format!("\t<key>application-identifier</key>\n\t<string>{appid}</string>\n\t<key>com.apple.developer.team-identifier</key>\n\t<string>{team}</string>\n</dict>\n</plist>\n");
    let xml_body = [HEAD.as_bytes(), body.as_bytes()].concat();
    let xml = [&be32(0xfade7171)[..], &be32(8 + xml_body.len() as u32), &xml_body].concat();
    let s = |v: &str| tlv(0x0c, v.as_bytes());
    let kv = [tlv(0x30, &[s("application-identifier"), s(appid)].concat()), tlv(0x30, &[s("com.apple.developer.team-identifier"), s(team)].concat())].concat();
    let d = tlv(0x70, &[tlv(0x02, &[1]), tlv(0xb0, &kv)].concat());
    let der = [&be32(0xfade7172)[..], &be32(8 + d.len() as u32), &d].concat();
    (xml, der)
}

// ---------- Mach-O ----------
fn sign(input: &[u8], bundle: &str, team: &str, key: &RsaKeyPair, leaf: &[u8]) -> Result<Vec<u8>, String> {
    if input.len() < 32 { return Err("文件太小".into()) }
    if rd32le(input, 0) != MH_MAGIC_64 || rd32le(input, 4) != CPU_TYPE_ARM64 { return Err(format!("不是 arm64 单架构 Mach-O（magic {:#x}）", rd32le(input, 0))) }
    let filetype = rd32le(input, 12);
    let ncmds = rd32le(input, 16);
    let (mut sig, mut le, mut text) = (None, None, (0u64, 0u64));
    let mut p = 32usize;
    for _ in 0..ncmds {
        if p + 8 > input.len() { return Err("加载命令越界".into()) }
        let (cmd, size) = (rd32le(input, p), rd32le(input, p + 4) as usize);
        if cmd == LC_CODE_SIGNATURE { sig = Some(p) }
        if cmd == LC_SEGMENT_64 {
            let name = &input[p + 8..p + 24];
            let name = &name[..name.iter().position(|&c| c == 0).unwrap_or(16)];
            if name == b"__LINKEDIT" { le = Some(p) }
            if name == b"__TEXT" { text = (rd64le(input, p + 40), rd64le(input, p + 48)) }
        }
        p += size;
    }
    let (Some(sig), Some(le)) = (sig, le) else { return Err("没有 LC_CODE_SIGNATURE / __LINKEDIT（要先有一份签名，ad-hoc 也行）".into()) };
    let limit = rd32le(input, sig + 8);
    let le_fileoff = rd64le(input, le + 40);
    if limit as usize > input.len() || le_fileoff > limit as u64 { return Err("签名偏移越界".into()) }
    let appid = format!("{team}.{bundle}");
    let req: Vec<u8> = [be32(0xfade0c01), be32(12), be32(0)].concat();
    let req_hash = sha256(&req);
    let (ex, ed) = build_ents(&appid, team);
    let (ent_hash, ent_der_hash) = (sha256(&ex), sha256(&ed));
    let nblob: u32 = 5;
    let ts = utc_now();
    let mut code = input[..limit as usize].to_vec();
    let (mut est, mut cd, mut cms) = (0u32, Vec::new(), Vec::new());
    for pass in 0..2 {
        if pass == 1 {   // 按估好的大小改 LC_CODE_SIGNATURE 与 __LINKEDIT
            code[sig + 12..sig + 16].copy_from_slice(&est.to_le_bytes());
            let filesize = limit as u64 + est as u64 - le_fileoff;
            code[le + 48..le + 56].copy_from_slice(&filesize.to_le_bytes());
            let vmsize = (filesize + PAGE as u64 - 1) & !(PAGE as u64 - 1);
            code[le + 32..le + 40].copy_from_slice(&vmsize.to_le_bytes());
        }
        cd = build_cd(&code, limit, bundle, team, &req_hash, &ent_hash, &ent_der_hash, text.0, text.1, if filetype == MH_EXECUTE { 1 } else { 0 });
        cms = build_cms(&sha256(&cd), key, leaf, &ts)?;
        let need = (12 + nblob as usize * 8 + cd.len() + req.len() + ex.len() + ed.len() + cms.len() + 8) as u32;
        if pass == 0 { est = (need + 1024 + 15) & !15 }   // 留 1 KiB 余量（同 selfsign.c）
        else if need > est { return Err(format!("签名比预留大（{need} > {est}）")) }
    }
    // SuperBlob：CodeDirectory(0) / Requirements(2) / XML 权限(5) / DER 权限(7) / CMS(0x10000)，索引按类型升序
    let off0 = 12 + nblob * 8;
    let off1 = off0 + cd.len() as u32;
    let offx = off1 + req.len() as u32;
    let offd = offx + ex.len() as u32;
    let off2 = offd + ed.len() as u32;
    let mut sb = Vec::new();
    sb.extend(be32(0xfade0cc0)); sb.extend(be32(0)); sb.extend(be32(nblob));
    for (t, o) in [(0, off0), (2, off1), (5, offx), (7, offd), (0x10000, off2)] { sb.extend(be32(t)); sb.extend(be32(o)) }
    sb.extend(&cd); sb.extend(&req); sb.extend(&ex); sb.extend(&ed);
    sb.extend(be32(0xfade0b01)); sb.extend(be32(cms.len() as u32 + 8)); sb.extend(&cms);   // CMS 包成 BlobWrapper
    if sb.len() > est as usize { return Err("SuperBlob 比预留大".into()) }
    let n = sb.len() as u32;
    sb[4..8].copy_from_slice(&be32(n));
    let mut out = code;
    out.extend(&sb);
    out.resize(limit as usize + est as usize, 0);
    Ok(out)
}

// ---------- 私钥（PEM：PKCS#1「RSA PRIVATE KEY」或 PKCS#8「PRIVATE KEY」）----------
fn pem_der(pem: &str) -> Option<(String, Vec<u8>)> {
    let start = pem.find("-----BEGIN ")?;
    let rest = &pem[start + 11..];
    let label_end = rest.find("-----")?;
    let label = rest[..label_end].to_string();
    let body_start = label_end + 5;
    let end = rest.find("-----END ")?;
    let mut bits = 0u32;
    let mut acc = 0u32;
    let mut out = Vec::new();
    for c in rest[body_start..end].bytes() {
        let v = match c { b'A'..=b'Z' => c - b'A', b'a'..=b'z' => c - b'a' + 26, b'0'..=b'9' => c - b'0' + 52, b'+' => 62, b'/' => 63, _ => continue } as u32;
        acc = acc << 6 | v;
        bits += 6;
        if bits >= 8 { bits -= 8; out.push((acc >> bits) as u8) }
    }
    Some((label, out))
}
fn load_key(path: &str) -> Result<RsaKeyPair, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("读不了私钥 {path}：{e}"))?;
    let (label, der) = pem_der(&text).ok_or(format!("{path} 不是 PEM 私钥"))?;
    match label.as_str() {
        "RSA PRIVATE KEY" => RsaKeyPair::from_der(&der).map_err(|e| format!("私钥（PKCS#1）解析不了：{e}")),
        "PRIVATE KEY" => RsaKeyPair::from_pkcs8(&der).map_err(|e| format!("私钥（PKCS#8）解析不了：{e}")),
        other => Err(format!("{path} 是「{other}」，要 RSA 私钥（PKCS#1 或 PKCS#8）")),
    }
}

fn usage() -> ! {
    eprintln!("用法：s2a-selfsign --key key.pem --cert cert.der --bundle-id <App 包名> --team <团队号> <dylib>");
    std::process::exit(2)
}
fn main() {
    let a: Vec<String> = std::env::args().skip(1).collect();
    let (mut key, mut cert, mut bundle, mut team, mut target) = (None, None, None, None, None);
    let mut i = 0;
    while i < a.len() {
        let v = || a.get(i + 1).cloned().unwrap_or_else(|| usage());
        match a[i].as_str() {
            "--key" => { key = Some(v()); i += 1 }
            "--cert" => { cert = Some(v()); i += 1 }
            "--bundle-id" => { bundle = Some(v()); i += 1 }
            "--team" => { team = Some(v()); i += 1 }
            s if !s.starts_with("--") && target.is_none() => target = Some(s.to_string()),
            _ => usage(),
        }
        i += 1;
    }
    let (Some(key), Some(cert), Some(bundle), Some(team), Some(target)) = (key, cert, bundle, team, target) else { usage() };
    let r = (|| -> Result<(), String> {
        let k = load_key(&key)?;
        let leaf = std::fs::read(&cert).map_err(|e| format!("读不了证书 {cert}：{e}"))?;
        let input = std::fs::read(&target).map_err(|e| format!("读不了 {target}：{e}"))?;
        let out = sign(&input, &bundle, &team, &k, &leaf)?;
        let tmp = format!("{target}.s2a-selfsign.tmp");
        std::fs::write(&tmp, &out).map_err(|e| format!("写不进 {tmp}：{e}"))?;
        std::fs::rename(&tmp, &target).map_err(|e| { let _ = std::fs::remove_file(&tmp); format!("换不上 {target}：{e}") })
    })();
    if let Err(e) = r {
        eprintln!("s2a-selfsign：{e}");
        std::process::exit(1)
    }
}
