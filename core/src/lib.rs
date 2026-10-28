mod bridge;

use bridge::Bridge;
use serde::Deserialize;
use serde_json::{json, Value};
use serialport::{ClearBuffer, SerialPort, SerialPortType};
use std::ffi::{c_char, CStr, CString};
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Request {
    RefreshPorts,
    Connect { path: String },
    Disconnect,
    Scan,
    StopScan,
    Pair,
    Toggle,
    Brightness { value: u8 },
    Temperature { value: u8 },
    Shutdown,
}

#[derive(Default)]
struct State {
    connected: bool,
    connecting: bool,
    scanning: bool,
    pairing: bool,
    remote_id: Option<String>,
    status: &'static str,
}

struct Worker {
    bridge: Option<Bridge<Box<dyn SerialPort>>>,
    state: State,
    events: mpsc::Sender<String>,
    cancel: Arc<AtomicBool>,
}

impl Worker {
    fn emit(&self, event: Value) {
        let _ = self.events.send(event.to_string());
    }

    fn state(&self) {
        self.emit(json!({
            "type": "state",
            "connected": self.state.connected,
            "connecting": self.state.connecting,
            "scanning": self.state.scanning,
            "pairing": self.state.pairing,
            "remoteId": self.state.remote_id,
            "status": self.state.status,
        }));
    }

    fn fail(&mut self, error: String) {
        self.bridge = None;
        self.state = State {
            status: "error",
            ..State::default()
        };
        self.state();
        self.emit(json!({ "type": "error", "message": error }));
    }

    fn ports(&self) {
        match serialport::available_ports() {
            Ok(mut ports) => {
                ports.sort_by(|a, b| a.port_name.cmp(&b.port_name));
                let ports: Vec<_> = ports.into_iter().map(|port| {
                    let (is_usb, is_likely_bridge, description) = match port.port_type {
                        SerialPortType::UsbPort(info) => (
                            true,
                            info.vid == 0x1a86 && info.pid == 0x7523,
                            info.product.or(info.manufacturer),
                        ),
                        _ => (false, false, None),
                    };
                    json!({ "path": port.port_name, "description": description, "isUsb": is_usb, "isLikelyBridge": is_likely_bridge })
                }).collect();
                self.emit(json!({ "type": "ports", "ports": ports }));
            }
            Err(error) => self.emit(
                json!({ "type": "error", "message": format!("port enumeration failed: {error}") }),
            ),
        }
    }

    fn connect(&mut self, path: String) {
        self.bridge = None;
        self.state = State {
            connecting: true,
            status: "connecting",
            ..State::default()
        };
        self.state();
        let result = (|| {
            let port = serialport::new(&path, 115_200)
                .timeout(Duration::from_millis(100))
                .open()
                .map_err(|error| format!("cannot open {path}: {error}"))?;
            // Nano boards may reset when a serial port is opened. PING works
            // whether or not this particular USB driver triggered a reset.
            thread::sleep(Duration::from_secs(2));
            let _ = port.clear(ClearBuffer::Input);
            let mut bridge = Bridge::new(port);
            let id = bridge.handshake()?;
            Ok::<_, String>((bridge, id))
        })();
        match result {
            Ok((bridge, id)) => {
                self.bridge = Some(bridge);
                self.state = State {
                    connected: true,
                    status: if id.is_some() {
                        "connected"
                    } else {
                        "awaiting_remote"
                    },
                    remote_id: id,
                    ..State::default()
                };
                self.state();
                if self.state.remote_id.is_none() {
                    self.scan();
                }
            }
            Err(error) => self.fail(error),
        }
    }

    fn scan(&mut self) {
        if self.bridge.is_none() {
            return;
        }
        self.state.scanning = true;
        self.state.status = "scanning";
        self.state();
        let result = self.bridge.as_mut().unwrap().scan(&self.cancel);
        match result {
            Ok(id) => {
                self.state.scanning = false;
                if let Some(id) = id {
                    self.state.remote_id = Some(id);
                    self.state.status = "remote_saved";
                } else {
                    self.state.status = "scan_stopped";
                }
                self.state();
            }
            Err(error) => self.fail(error),
        }
    }

    fn pair(&mut self) {
        if self.bridge.is_none() {
            return;
        }
        self.state.pairing = true;
        self.state.status = "pairing";
        self.state();
        let result = (|| {
            let mut bytes = [0u8; 3];
            getrandom::fill(&mut bytes)
                .map_err(|error| format!("cannot generate remote ID: {error}"))?;
            if bytes == [0, 0, 0] || bytes == [255, 255, 255] {
                bytes[2] = 1;
            }
            let id = format!("{:02X}:{:02X}:{:02X}", bytes[0], bytes[1], bytes[2]);
            self.bridge.as_mut().unwrap().pair(&id)?;
            Ok::<_, String>(id)
        })();
        match result {
            Ok(id) => {
                self.state.remote_id = Some(id);
                self.state.pairing = false;
                self.state.status = "pair_sent";
                self.state();
            }
            Err(error) => self.fail(error),
        }
    }

    fn control(&mut self, request: Request) {
        if !self.state.connected || self.state.remote_id.is_none() {
            return;
        }
        self.state.status = "sending";
        self.state();
        let bridge = self.bridge.as_mut().unwrap();
        let result = match request {
            Request::Toggle => bridge.send("ON"),
            Request::Brightness { value } => bridge.set_level(0x04, value),
            Request::Temperature { value } => bridge.set_level(0x02, value),
            _ => return,
        };
        match result {
            Ok(()) => {
                self.state.status = "sent";
                self.state();
            }
            Err(error) => self.fail(error),
        }
    }

    fn run(mut self, requests: mpsc::Receiver<Request>) {
        self.state.status = "disconnected";
        self.state();
        while let Ok(request) = requests.recv() {
            match request {
                Request::RefreshPorts => self.ports(),
                Request::Connect { path } => self.connect(path),
                Request::Disconnect => {
                    self.bridge = None;
                    self.state = State {
                        status: "disconnected",
                        ..State::default()
                    };
                    self.state();
                }
                Request::Scan => self.scan(),
                Request::StopScan => {}
                Request::Pair => self.pair(),
                Request::Toggle | Request::Brightness { .. } | Request::Temperature { .. } => {
                    self.control(request)
                }
                Request::Shutdown => break,
            }
        }
    }
}

/// Opaque controller shared with desktop UI processes via a C ABI. A worker
/// thread owns the serial port, and the UI polls a non-blocking event queue.
pub struct Controller {
    requests: mpsc::Sender<Request>,
    events: Mutex<mpsc::Receiver<String>>,
    cancel: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
}

impl Drop for Controller {
    fn drop(&mut self) {
        self.cancel.store(true, Ordering::Release);
        let _ = self.requests.send(Request::Shutdown);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

#[no_mangle]
pub extern "C" fn lightbar_create() -> *mut Controller {
    let (requests_tx, requests_rx) = mpsc::channel();
    let (events_tx, events_rx) = mpsc::channel();
    let cancel = Arc::new(AtomicBool::new(false));
    let worker = Worker {
        bridge: None,
        state: State::default(),
        events: events_tx,
        cancel: cancel.clone(),
    };
    let handle = thread::spawn(move || worker.run(requests_rx));
    Box::into_raw(Box::new(Controller {
        requests: requests_tx,
        events: Mutex::new(events_rx),
        cancel,
        worker: Some(handle),
    }))
}

/// Accepts a UTF-8, NUL-terminated JSON request. Returns zero on success.
#[no_mangle]
pub unsafe extern "C" fn lightbar_send(controller: *mut Controller, request: *const c_char) -> i32 {
    if controller.is_null() || request.is_null() {
        return -1;
    }
    let Ok(text) = CStr::from_ptr(request).to_str() else {
        return -2;
    };
    let Ok(request) = serde_json::from_str::<Request>(text) else {
        return -3;
    };
    let controller = &*controller;
    match &request {
        Request::Connect { .. } | Request::Scan => {
            controller.cancel.store(false, Ordering::Release)
        }
        Request::StopScan | Request::Disconnect | Request::Pair | Request::Shutdown => {
            controller.cancel.store(true, Ordering::Release)
        }
        _ => {}
    }
    if controller.requests.send(request).is_ok() {
        0
    } else {
        -4
    }
}

/// Returns one owned UTF-8 event or null when the queue is empty.
#[no_mangle]
pub unsafe extern "C" fn lightbar_next_event(controller: *mut Controller) -> *mut c_char {
    if controller.is_null() {
        return ptr::null_mut();
    }
    let Ok(receiver) = (*controller).events.lock() else {
        return ptr::null_mut();
    };
    match receiver.try_recv() {
        Ok(event) => CString::new(event).map_or(ptr::null_mut(), CString::into_raw),
        Err(_) => ptr::null_mut(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn lightbar_free_string(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

#[no_mangle]
pub unsafe extern "C" fn lightbar_destroy(controller: *mut Controller) {
    if !controller.is_null() {
        drop(Box::from_raw(controller));
    }
}
