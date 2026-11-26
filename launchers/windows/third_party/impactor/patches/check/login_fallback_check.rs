// S2Arm：补丁里「默认 anisette 服务器被 SRP -23782 拒绝才换备用服务器」的控制流检查（tools/plumesign_build.py 编之前跑）。
// 假的「登录一次」：默认服务器回 -23782、备用服务器成功；核 ① 换服务器重试成功 ② 选择记进数据目录 ③ 下次直接用备用只试一次
// ④ 别的错误不重试不换 ⑤ 已在备用又被拒不再重试。
use omnisette::*;
use plume_core::Error;
use plume_core::auth::account::login_with_anisette_fallback;
use std::sync::Mutex;

fn main() {
    tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap().block_on(run());
}

async fn run() {
    let dir = std::env::temp_dir().join(format!("s2a-login-fallback-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let config = AnisetteConfiguration::new().set_configuration_path(dir.clone());
    let seen = Mutex::new(Vec::<String>::new());
    // 假的「登录一次」：缺省服务器回 -23782，备用服务器成功
    let attempt = |c: AnisetteConfiguration| {
        let url = c.effective_anisette_url_v3();
        seen.lock().unwrap().push(url.clone());
        async move {
            if url == DEFAULT_ANISETTE_URL_V3 {
                Err(Error::AuthSrpWithMessage(-23782, "A Mac with macOS 10.13 or later is required".into()))
            } else {
                Ok(url)
            }
        }
    };
    // ① 第一次：缺省被拒 → 换备用重试成功
    let r = login_with_anisette_fallback(config.clone(), || "a@b.c".into(), &attempt).await;
    assert_eq!(r.unwrap(), FALLBACK_ANISETTE_URL_V3);
    assert_eq!(*seen.lock().unwrap(), vec![DEFAULT_ANISETTE_URL_V3.to_string(), FALLBACK_ANISETTE_URL_V3.to_string()]);
    // ② 选择记进数据目录
    assert_eq!(std::fs::read_to_string(dir.join(V3_URL_FILE)).unwrap().trim(), FALLBACK_ANISETTE_URL_V3);
    // ③ 下次直接用备用，只试一次
    seen.lock().unwrap().clear();
    let r = login_with_anisette_fallback(config.clone(), || "a@b.c".into(), &attempt).await;
    assert_eq!(r.unwrap(), FALLBACK_ANISETTE_URL_V3);
    assert_eq!(seen.lock().unwrap().len(), 1);
    // ④ 别的错误不重试、不换服务器（新数据目录）
    let dir2 = dir.with_extension("other");
    let _ = std::fs::remove_dir_all(&dir2);
    let c2 = AnisetteConfiguration::new().set_configuration_path(dir2.clone());
    let n = Mutex::new(0);
    let other = |_c: AnisetteConfiguration| { *n.lock().unwrap() += 1; async { Err::<String, _>(Error::AuthSrpWithMessage(-22406, "wrong password".into())) } };
    assert!(login_with_anisette_fallback(c2.clone(), || "a@b.c".into(), &other).await.is_err());
    assert_eq!((*n.lock().unwrap(), c2.effective_anisette_url_v3()), (1, DEFAULT_ANISETTE_URL_V3.to_string()));
    // ⑤ 已在备用服务器上又被 -23782：不再重试（只试一次，不死循环）
    seen.lock().unwrap().clear();
    let always = |c: AnisetteConfiguration| { seen.lock().unwrap().push(c.effective_anisette_url_v3()); async { Err::<String, _>(Error::AuthSrpWithMessage(-23782, "x".into())) } };
    assert!(login_with_anisette_fallback(config.clone(), || "a@b.c".into(), &always).await.is_err());
    assert_eq!(seen.lock().unwrap().len(), 1);
    let _ = std::fs::remove_dir_all(&dir); let _ = std::fs::remove_dir_all(&dir2);
    println!("登录回退 5 项全过");
}
