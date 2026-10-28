use std::collections::VecDeque;
use std::io::{self, Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

const COMMAND_TIMEOUT: Duration = Duration::from_secs(5);

/// A single reader owns the stream for the lifetime of a connection. In
/// particular, bytes read together with an acknowledgement are retained for
/// the scanner instead of being lost in a second buffered reader.
pub struct Bridge<T> {
    port: T,
    input: Vec<u8>,
    deferred: VecDeque<String>,
    pub remote_id: Option<String>,
}

impl<T: Read + Write> Bridge<T> {
    pub fn new(port: T) -> Self {
        Self {
            port,
            input: Vec::new(),
            deferred: VecDeque::new(),
            remote_id: None,
        }
    }

    fn read_line(&mut self, deadline: Instant) -> Result<Option<String>, String> {
        loop {
            if let Some(end) = self.input.iter().position(|byte| *byte == b'\n') {
                let line: Vec<u8> = self.input.drain(..=end).collect();
                return Ok(Some(String::from_utf8_lossy(&line).trim().to_owned()));
            }
            if Instant::now() >= deadline {
                return Ok(None);
            }
            let mut buffer = [0; 256];
            match self.port.read(&mut buffer) {
                Ok(0) => return Err("serial port closed".into()),
                Ok(count) => self.input.extend_from_slice(&buffer[..count]),
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::TimedOut
                            | io::ErrorKind::WouldBlock
                            | io::ErrorKind::Interrupted
                    ) => {}
                Err(error) => return Err(format!("serial read failed: {error}")),
            }
        }
    }

    fn command(&mut self, command: &str, expected: &str) -> Result<String, String> {
        self.port
            .write_all(format!("{command}\n").as_bytes())
            .and_then(|_| self.port.flush())
            .map_err(|error| format!("serial write failed: {error}"))?;
        let deadline = Instant::now() + COMMAND_TIMEOUT;
        while let Some(line) = self.read_line(deadline)? {
            if line.starts_with("ERR") {
                return Err(line);
            }
            if line.starts_with(expected) {
                return Ok(line);
            }
            if line.starts_with("FOUND:") {
                self.deferred.push_back(line);
            }
        }
        Err(format!("device did not respond to {command}"))
    }

    pub fn handshake(&mut self) -> Result<Option<String>, String> {
        self.command("PING", "READY")?;
        let response = self.command("GET_ID", "ID:")?;
        let id = response.trim_start_matches("ID:").to_ascii_uppercase();
        self.remote_id = if valid_id(&id) { Some(id) } else { None };
        Ok(self.remote_id.clone())
    }

    pub fn scan(&mut self, cancelled: &AtomicBool) -> Result<Option<String>, String> {
        if cancelled.load(Ordering::Acquire) {
            return Ok(None);
        }
        self.deferred.clear();
        self.command("SCAN", "OK")?;
        let result = (|| {
            while !cancelled.load(Ordering::Acquire) {
                let line = if let Some(line) = self.deferred.pop_front() {
                    Some(line)
                } else {
                    self.read_line(Instant::now() + Duration::from_millis(100))?
                };
                if let Some(line) = line {
                    if line.starts_with("ERR") {
                        return Err(line);
                    }
                    if let Some(id) = line.strip_prefix("FOUND:") {
                        let id = id.to_ascii_uppercase();
                        if valid_id(&id) {
                            return Ok(Some(id));
                        }
                    }
                }
            }
            Ok(None)
        })();
        let stopped = self.command("SCAN_STOP", "OK");
        let found = result?;
        stopped?;
        // A cancelled scan must never replace an existing ID.
        if let Some(id) = found
            .as_ref()
            .filter(|_| !cancelled.load(Ordering::Acquire))
        {
            self.command(&format!("ID {id}"), "OK")?;
            self.remote_id = Some(id.clone());
            return Ok(Some(id.clone()));
        }
        Ok(None)
    }

    pub fn pair(&mut self, id: &str) -> Result<(), String> {
        if !valid_id(id) {
            return Err("invalid remote ID".into());
        }
        self.command(&format!("ID {id}"), "OK")?;
        self.remote_id = Some(id.to_owned());
        self.command("PAIR", "OK")?;
        Ok(())
    }

    pub fn send(&mut self, command: &str) -> Result<(), String> {
        if self.remote_id.is_none() {
            return Err("remote ID has not been set".into());
        }
        self.command(command, "OK")?;
        Ok(())
    }

    pub fn set_level(&mut self, command_byte: u8, level: u8) -> Result<(), String> {
        if !matches!(command_byte, 0x02 | 0x04) || level > 15 {
            return Err("invalid level".into());
        }
        self.send(&format!("CMD {command_byte:02X} F0"))?;
        self.send(&format!("CMD {command_byte:02X} {level:02X}"))
    }
}

pub fn valid_id(id: &str) -> bool {
    let bytes = id.as_bytes();
    bytes.len() == 8
        && bytes[2] == b':'
        && bytes[5] == b':'
        && bytes
            .iter()
            .enumerate()
            .all(|(i, byte)| i == 2 || i == 5 || byte.is_ascii_hexdigit())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    struct FakePort {
        incoming: VecDeque<u8>,
        commands: Arc<Mutex<Vec<String>>>,
        captured_id: bool,
        cancel_on_scan: Option<Arc<AtomicBool>>,
    }
    impl FakePort {
        fn new(captured_id: bool) -> (Self, Arc<Mutex<Vec<String>>>) {
            let commands = Arc::new(Mutex::new(Vec::new()));
            (
                Self {
                    incoming: VecDeque::new(),
                    commands: commands.clone(),
                    captured_id,
                    cancel_on_scan: None,
                },
                commands,
            )
        }
    }
    impl Read for FakePort {
        fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
            if self.incoming.is_empty() {
                return Err(io::ErrorKind::TimedOut.into());
            }
            let count = output.len().min(self.incoming.len());
            for byte in &mut output[..count] {
                *byte = self.incoming.pop_front().unwrap();
            }
            Ok(count)
        }
    }
    impl Write for FakePort {
        fn write(&mut self, input: &[u8]) -> io::Result<usize> {
            let command = String::from_utf8_lossy(input).trim().to_string();
            self.commands.lock().unwrap().push(command.clone());
            if command == "SCAN" {
                if let Some(cancel) = &self.cancel_on_scan {
                    cancel.store(true, Ordering::Release);
                }
            }
            let response = match command.as_str() {
                "PING" => "READY\n",
                "GET_ID" => "ID:none\n",
                "SCAN" if self.captured_id => "OK\nFOUND:0A:05:F1\nFOUND:0A:05:F1\n",
                _ => "OK\n",
            };
            self.incoming.extend(response.bytes());
            Ok(input.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn handshake_scans_buffered_packet_and_sets_levels() {
        let (port, commands) = FakePort::new(true);
        let mut bridge = Bridge::new(port);
        assert_eq!(bridge.handshake().unwrap(), None);
        assert_eq!(
            bridge.scan(&AtomicBool::new(false)).unwrap().as_deref(),
            Some("0A:05:F1")
        );
        bridge.set_level(0x04, 15).unwrap();
        bridge.set_level(0x02, 7).unwrap();
        assert!(bridge.set_level(0x04, 16).is_err());
        assert_eq!(
            *commands.lock().unwrap(),
            [
                "PING",
                "GET_ID",
                "SCAN",
                "SCAN_STOP",
                "ID 0A:05:F1",
                "CMD 04 F0",
                "CMD 04 0F",
                "CMD 02 F0",
                "CMD 02 07"
            ]
        );
    }

    #[test]
    fn cancelled_scan_stops_without_replacing_id() {
        let (mut port, commands) = FakePort::new(true);
        let cancel = Arc::new(AtomicBool::new(false));
        port.cancel_on_scan = Some(cancel.clone());
        let mut bridge = Bridge::new(port);
        bridge.remote_id = Some("12:34:56".into());
        assert_eq!(bridge.scan(&cancel).unwrap(), None);
        assert_eq!(bridge.remote_id.as_deref(), Some("12:34:56"));
        assert_eq!(*commands.lock().unwrap(), ["SCAN", "SCAN_STOP"]);
    }

    #[test]
    fn pairing_persists_id_before_pairing() {
        let (port, commands) = FakePort::new(false);
        let mut bridge = Bridge::new(port);
        bridge.pair("12:34:56").unwrap();
        bridge.send("ON").unwrap();
        assert_eq!(*commands.lock().unwrap(), ["ID 12:34:56", "PAIR", "ON"]);
        assert!(!valid_id("12:34:5G"));
    }
}
