// 连接中途断了不能一直挂着（真机实测：推送中途 App 被重装，进度停在 86%、20 分钟没有任何输出）：
//   起一个只接连接、从不回话的假 Apple 设备服务，s2a-devpush 应在 S2A_DEVPUSH_STALL_SECONDS 到点后报错退 1，不是无限期等下去
use std::{io::Read, net::TcpListener, process::{Command, Stdio}, thread, time::{Duration, Instant}};

#[test]
fn silent_device_service_times_out_instead_of_hanging() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    thread::spawn(move || { let _held: Vec<_> = listener.incoming().take(4).collect(); thread::sleep(Duration::from_secs(60)); });
    let started = Instant::now();
    let mut child = Command::new(env!("CARGO_BIN_EXE_s2a-devpush"))
        .args(["U1", "io.example", "put", "Cargo.toml", "Documents/x"])
        .env("USBMUXD_SOCKET_ADDRESS", format!("127.0.0.1:{port}"))
        .env("S2A_DEVPUSH_STALL_SECONDS", "2")
        .stdout(Stdio::null()).stderr(Stdio::piped())
        .spawn().unwrap();
    let status = loop {   // 自己设 20 秒上限：旧版会一直挂着，测试不能跟着挂
        if let Some(s) = child.try_wait().unwrap() { break s; }
        if started.elapsed() > Duration::from_secs(20) { child.kill().unwrap(); panic!("20 秒还没退出：卡住了没有超时"); }
        thread::sleep(Duration::from_millis(100));
    };
    let mut err = String::new(); child.stderr.take().unwrap().read_to_string(&mut err).unwrap();
    assert_eq!(status.code(), Some(1));
    assert!(started.elapsed() >= Duration::from_secs(2), "不到上限就退了：{:?}", started.elapsed());
    assert!(err.contains("没有任何进展"), "报错没说原因：{err}");
}
