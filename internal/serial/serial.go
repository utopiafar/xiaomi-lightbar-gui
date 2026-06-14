package serial

import (
	"bufio"
	"fmt"
	"strings"
	"time"

	goserial "go.bug.st/serial"
)

// Port wraps a serial connection to the RF-NANO.
type Port struct {
	port   goserial.Port
	reader *bufio.Reader
}

// Open opens the serial port at 115200 baud and waits for the READY line.
func Open(device string) (*Port, error) {
	mode := &goserial.Mode{
		BaudRate: 115200,
		DataBits: 8,
		Parity:   goserial.NoParity,
		StopBits: goserial.OneStopBit,
	}
	p, err := goserial.Open(device, mode)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", device, err)
	}
	if err := p.SetReadTimeout(3 * time.Second); err != nil {
		p.Close()
		return nil, fmt.Errorf("set timeout: %w", err)
	}

	sp := &Port{
		port:   p,
		reader: bufio.NewReader(p),
	}

	// Wait for READY (the firmware sends it after NRF24 init).
	// Allow up to 5 seconds for the Arduino to reset and boot.
	if err := p.SetReadTimeout(5 * time.Second); err != nil {
		p.Close()
		return nil, err
	}
	// Read lines until we see one that ends with "READY".
	// The first byte from Arduino after DTR-reset is often corrupted,
	// so we match by suffix rather than exact equality.
	for {
		line, err := sp.ReadLine()
		if err != nil {
			p.Close()
			return nil, fmt.Errorf("waiting for READY: %w", err)
		}
		if strings.HasSuffix(line, "READY") {
			break
		}
	}

	// Restore normal 3 s read timeout.
	if err := p.SetReadTimeout(3 * time.Second); err != nil {
		p.Close()
		return nil, err
	}

	return sp, nil
}

// Close closes the underlying serial port.
func (s *Port) Close() error {
	return s.port.Close()
}

// SendCommand sends a line (newline appended) and returns the response line.
//
// Opening the port toggles DTR, which can spuriously reset the Arduino; the
// firmware then emits a fresh "READY" banner. Since READY is never a valid
// command reply, treat it as a reset signal: let the board settle and resend
// the command (so a command lost to the reset, e.g. ID, is not dropped).
func (s *Port) SendCommand(cmd string) (string, error) {
	for attempt := 0; attempt < 3; attempt++ {
		if _, err := fmt.Fprintf(s.port, "%s\n", cmd); err != nil {
			return "", fmt.Errorf("write: %w", err)
		}
		resp, err := s.readResponse()
		if err != nil {
			return "", fmt.Errorf("read response: %w", err)
		}
		if strings.HasSuffix(resp, "READY") {
			time.Sleep(200 * time.Millisecond)
			continue
		}
		return resp, nil
	}
	return "", fmt.Errorf("command %q kept racing Arduino resets", cmd)
}

// readResponse returns the next non-empty line, skipping blanks and the
// stray garbage byte that often trails an Arduino reset.
func (s *Port) readResponse() (string, error) {
	for {
		line, err := s.ReadLine()
		if err != nil {
			return "", err
		}
		if line == "" {
			continue
		}
		return line, nil
	}
}

// ReadLine reads until \n and returns the trimmed line.
func (s *Port) ReadLine() (string, error) {
	line, err := s.reader.ReadString('\n')
	if err != nil {
		return "", err
	}
	return strings.TrimRight(line, "\r\n"), nil
}

// RawPort exposes the underlying port for scan loops that need direct reads.
func (s *Port) RawPort() goserial.Port {
	return s.port
}
