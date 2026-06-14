// lamp — CLI to control Xiaomi Mijia MJGJD01YL via RF-NANO
//
// Usage:
//
//	lamp scan    --port /dev/ttyUSB0           scan for remote ID (auto-saves on exit)
//	lamp set-id  --port ... [AA:BB:CC]         save Remote ID to firmware and config
//	lamp on      --port ...
//	lamp off     --port ...
//	lamp bright  --port ... +5                 brightness step (1..15)
//	lamp warm    --port ... -3                 colour temp step (1..15)
//	lamp reset   --port ...
//	lamp config                                show saved config
package main

import (
	"bufio"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/alxndrchernov/auto-lamp/internal/config"
	"github.com/alxndrchernov/auto-lamp/internal/serial"
)

func usage() {
	fmt.Fprint(os.Stderr, `Usage: lamp <command> [flags] [args]

Commands:
  pair  [AA:BB:CC]  Bind the lamp to an ID of your choice (no original remote needed)
  scan              Scan for original remote ID (auto-saves to config + firmware on exit)
  set-id [AA:BB:CC] Store Remote ID in firmware EEPROM and config (uses saved ID if omitted)
  on                Turn lamp on
  off               Turn lamp off
  bright +N / -N    Adjust brightness (N = 1..15)
  warm   +N / -N    Adjust colour temperature (N = 1..15)
  reset             Factory reset the lamp
  config            Show saved configuration

Flags:
  --port string   Serial port device (default from config, then /dev/ttyUSB0)
`)
	os.Exit(1)
}

func main() {
	if len(os.Args) < 2 {
		usage()
	}

	cfg := config.Load()

	subcmd := os.Args[1]
	port, args := parseArgs(os.Args[2:], cfg)

	arg0 := ""
	if len(args) > 0 {
		arg0 = args[0]
	}

	switch subcmd {
	case "pair":
		runPair(port, arg0, cfg)
	case "scan":
		runScan(port, cfg)
	case "set-id":
		id := arg0
		if id == "" {
			id = cfg.ID
		}
		if id == "" {
			fmt.Fprintln(os.Stderr, "set-id: no ID given and none saved (run 'lamp scan' first)")
			os.Exit(1)
		}
		runSetID(port, id, cfg)
	case "on":
		runSimple(port, "ON")
	case "off":
		runSimple(port, "OFF")
	case "bright":
		if len(args) < 1 {
			fmt.Fprintln(os.Stderr, "bright requires +N or -N")
			os.Exit(1)
		}
		runSimple(port, "BRIGHT "+arg0)
	case "warm":
		if len(args) < 1 {
			fmt.Fprintln(os.Stderr, "warm requires +N or -N")
			os.Exit(1)
		}
		runSimple(port, "WARM "+arg0)
	case "reset":
		runSimple(port, "RESET")
	case "config":
		runShowConfig(cfg)
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %q\n\n", subcmd)
		usage()
	}
}

// parseArgs extracts the --port option and returns it plus the remaining
// positional arguments. It is hand-rolled (instead of the stdlib flag package)
// because brightness/warm values are signed, e.g. "-3", which flag would
// mistake for an undefined flag. Supports "--port X", "--port=X" (and the
// single-dash forms). The port defaults to the config value, then /dev/ttyUSB0.
func parseArgs(in []string, cfg *config.Config) (port string, args []string) {
	port = cfg.Port
	if port == "" {
		port = "/dev/ttyUSB0"
	}
	for i := 0; i < len(in); i++ {
		a := in[i]
		switch {
		case a == "--port" || a == "-port":
			if i+1 >= len(in) {
				fmt.Fprintln(os.Stderr, "--port needs a value")
				os.Exit(1)
			}
			port = in[i+1]
			i++
		case strings.HasPrefix(a, "--port="):
			port = strings.TrimPrefix(a, "--port=")
		case strings.HasPrefix(a, "-port="):
			port = strings.TrimPrefix(a, "-port=")
		default:
			args = append(args, a)
		}
	}
	return port, args
}

// runSimple opens the port, sends a single command, prints the response.
func runSimple(portDev, cmd string) {
	sp, err := openPort(portDev)
	if err != nil {
		fatal(err)
	}
	defer sp.Close()

	resp, err := sp.SendCommand(cmd)
	if err != nil {
		fatal(err)
	}
	fmt.Println(resp)
}

// runSetID sends "ID AA:BB:CC" to the firmware (saved to EEPROM there) and
// updates the local config file.
func runSetID(portDev, id string, cfg *config.Config) {
	id = strings.ToUpper(strings.TrimSpace(id))
	sp, err := openPort(portDev)
	if err != nil {
		fatal(err)
	}
	defer sp.Close()

	resp, err := sp.SendCommand("ID " + id)
	if err != nil {
		fatal(err)
	}
	fmt.Println(resp)

	cfg.ID = id
	cfg.Port = portDev
	if err := cfg.Save(); err != nil {
		fmt.Fprintln(os.Stderr, "warning: could not save config:", err)
	} else {
		fmt.Fprintf(os.Stderr, "Saved to %s\n", config.Path())
	}
}

// runPair binds the lamp to a chosen Remote ID without needing the original
// remote. The lamp accepts a new ID only in a ~20 s window after power-on, so
// the flow is: set the ID in firmware, have the user power-cycle the lamp,
// then fire the pairing (reset) burst. The lamp flashes once when bound.
func runPair(portDev, idArg string, cfg *config.Config) {
	id := strings.ToUpper(strings.TrimSpace(idArg))
	if id == "" {
		id = cfg.ID // reuse the saved ID if the user did not pass one
	}
	if id == "" {
		id = "11:11:11" // arbitrary default — any 3-byte value works
	}

	sp, err := openPort(portDev)
	if err != nil {
		fatal(err)
	}
	defer sp.Close()

	resp, err := sp.SendCommand("ID " + id)
	if err != nil {
		fatal(err)
	}
	if resp != "OK" {
		fmt.Fprintf(os.Stderr, "firmware error: %s\n", resp)
		os.Exit(1)
	}

	cfg.ID = id
	cfg.Port = portDev
	if err := cfg.Save(); err != nil {
		fmt.Fprintln(os.Stderr, "warning: could not save config:", err)
	}

	fmt.Printf("Pairing the lamp to ID %s\n\n", id)
	fmt.Println("  1. Unplug the lamp from power.")
	fmt.Println("  2. Plug it back in.")
	fmt.Print("  3. Within a few seconds, press Enter here… ")

	bufio.NewReader(os.Stdin).ReadString('\n')

	resp, err = sp.SendCommand("PAIR")
	if err != nil {
		fatal(err)
	}
	if resp != "OK" {
		fmt.Fprintf(os.Stderr, "firmware error: %s\n", resp)
		os.Exit(1)
	}

	fmt.Println("\nSent pairing burst. The lamp should flash once if it bound.")
	fmt.Println("Test it now:  lamp on")
}

// runScan enters sniffer mode and prints Remote IDs until Ctrl-C.
// The first found ID is automatically saved to firmware EEPROM and config.
func runScan(portDev string, cfg *config.Config) {
	sp, err := openPort(portDev)
	if err != nil {
		fatal(err)
	}
	defer sp.Close()

	resp, err := sp.SendCommand("SCAN")
	if err != nil {
		fatal(err)
	}
	if resp != "OK" {
		fmt.Fprintf(os.Stderr, "firmware error: %s\n", resp)
		os.Exit(1)
	}

	fmt.Fprintln(os.Stderr, "Scanning… press the original remote. Ctrl-C to stop.")

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)

	// The scanner goroutine reads from the raw port. After the loop we write
	// directly to the raw port (fire-and-forget) to avoid reader conflicts.
	scanner := bufio.NewScanner(sp.RawPort())
	lineCh := make(chan string, 16)
	go func() {
		for scanner.Scan() {
			lineCh <- strings.TrimRight(scanner.Text(), "\r\n")
		}
		close(lineCh)
	}()

	seen := map[string]bool{}
	foundID := ""
loop:
	for {
		select {
		case <-sig:
			break loop
		case line, ok := <-lineCh:
			if !ok {
				break loop
			}
			if strings.HasPrefix(line, "FOUND:") {
				id := strings.TrimPrefix(line, "FOUND:")
				if !seen[id] {
					seen[id] = true
					if foundID == "" {
						foundID = id
					}
					fmt.Println(id)
				}
			}
		}
	}

	fmt.Fprintln(os.Stderr, "\nScan stopped.")

	// Write directly to avoid conflict with scanner's internal buffer.
	fmt.Fprintf(sp.RawPort(), "SCAN_STOP\n")

	if foundID != "" {
		time.Sleep(100 * time.Millisecond)
		fmt.Fprintf(sp.RawPort(), "ID %s\n", foundID)
		time.Sleep(100 * time.Millisecond)

		cfg.ID = foundID
		cfg.Port = portDev
		if err := cfg.Save(); err != nil {
			fmt.Fprintln(os.Stderr, "warning: could not save config:", err)
		} else {
			fmt.Fprintf(os.Stderr, "Remote ID %s saved to %s\n", foundID, config.Path())
		}
	}
}

// runShowConfig prints the current saved configuration.
func runShowConfig(cfg *config.Config) {
	fmt.Printf("Config: %s\n", config.Path())
	if cfg.Port != "" {
		fmt.Printf("  port: %s\n", cfg.Port)
	} else {
		fmt.Println("  port: (not set)")
	}
	if cfg.ID != "" {
		fmt.Printf("  id:   %s\n", cfg.ID)
	} else {
		fmt.Println("  id:   (not set — run 'lamp scan' to detect)")
	}
}

func openPort(portDev string) (*serial.Port, error) {
	fmt.Fprintf(os.Stderr, "Opening %s…\n", portDev)
	sp, err := serial.Open(portDev)
	if err != nil {
		return nil, fmt.Errorf("cannot open serial port: %w", err)
	}
	return sp, nil
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}
