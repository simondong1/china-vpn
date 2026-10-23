package main

import (
	"encoding/json"
	"fmt"
	"io/ioutil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

type Config struct {
	Server    string `json:"server"`
	Port      int    `json:"port"`
	UUID      string `json:"uuid"`
	PublicKey string `json:"publicKey"`
	ShortID   string `json:"shortId"`
	SNI       string `json:"sni"`
}

func main() {
	if len(os.Args) < 2 {
		fmt.Println("Usage: vpn [import|connect|disconnect|status]")
		os.Exit(1)
	}

	home, _ := os.UserHomeDir()
	configDir := filepath.Join(home, ".vpn")
	os.MkdirAll(configDir, 0755)
	configFile := filepath.Join(configDir, "config.json")
	xrayBin := filepath.Join(configDir, "xray")
	xrayConfig := filepath.Join(configDir, "xray-config.json")
	pidFile := filepath.Join(configDir, "xray.pid")

	switch os.Args[1] {
	case "import":
		importConfig(configFile)
	case "connect":
		connect(configFile, xrayBin, xrayConfig, pidFile)
	case "disconnect":
		disconnect(pidFile)
	case "status":
		status(pidFile)
	default:
		fmt.Println("Unknown command. Use: import, connect, disconnect, or status")
	}
}

func importConfig(configFile string) {
	data, err := ioutil.ReadAll(os.Stdin)
	if err != nil {
		fmt.Println("Error reading input:", err)
		os.Exit(1)
	}

	link := strings.TrimSpace(string(data))
	if !strings.HasPrefix(link, "vless://") {
		fmt.Println("Error: not a vless:// link")
		os.Exit(1)
	}

	config := parseVlessLink(link)
	jsonData, _ := json.MarshalIndent(config, "", "  ")
	ioutil.WriteFile(configFile, jsonData, 0600)
	fmt.Println("Config imported successfully")
}

func parseVlessLink(link string) Config {
	link = strings.TrimPrefix(link, "vless://")
	parts := strings.SplitN(link, "@", 2)
	uuid := parts[0]

	rest := parts[1]
	hostPort := strings.SplitN(rest, "?", 2)[0]
	queryStr := strings.SplitN(rest, "?", 2)[1]

	host := strings.Split(hostPort, ":")[0]
	port := 443

	query, _ := url.ParseQuery(queryStr)
	return Config{
		Server:    host,
		Port:      port,
		UUID:      uuid,
		PublicKey: query.Get("pbk"),
		ShortID:   query.Get("sid"),
		SNI:       query.Get("sni"),
	}
}

func connect(configFile, xrayBin, xrayConfig, pidFile string) {
	data, err := ioutil.ReadFile(configFile)
	if err != nil {
		fmt.Println("Error: no config found. Run 'vpn import' first")
		os.Exit(1)
	}

	var config Config
	json.Unmarshal(data, &config)

	if _, err := os.Stat(xrayBin); os.IsNotExist(err) {
		fmt.Println("Downloading Xray...")
		downloadXray(xrayBin)
	}

	xrayJSON := generateXrayConfig(config)
	ioutil.WriteFile(xrayConfig, []byte(xrayJSON), 0600)

	fmt.Println("Starting Xray...")
	cmd := exec.Command(xrayBin, "run", "-c", xrayConfig)
	cmd.Start()

	ioutil.WriteFile(pidFile, []byte(fmt.Sprintf("%d", cmd.Process.Pid)), 0600)
	fmt.Printf("Connected! SOCKS5 proxy running on 127.0.0.1:10808\n")
	fmt.Println("Configure your browser or system to use this proxy")
}

func disconnect(pidFile string) {
	data, err := ioutil.ReadFile(pidFile)
	if err != nil {
		fmt.Println("VPN not running")
		return
	}

	var pid int
	fmt.Sscanf(string(data), "%d", &pid)
	process, _ := os.FindProcess(pid)
	process.Kill()
	os.Remove(pidFile)
	fmt.Println("Disconnected")
}

func status(pidFile string) {
	if _, err := os.Stat(pidFile); os.IsNotExist(err) {
		fmt.Println("Status: Disconnected")
	} else {
		fmt.Println("Status: Connected (SOCKS5 on 127.0.0.1:10808)")
	}
}

func downloadXray(dest string) {
	arch := "amd64"
	if strings.Contains(exec.Command("uname", "-m").String(), "arm64") {
		arch = "arm64"
	}
	url := fmt.Sprintf("https://github.com/XTLS/Xray-core/releases/download/v1.8.7/Xray-darwin-%s.zip", arch)

	exec.Command("curl", "-L", "-o", "/tmp/xray.zip", url).Run()
	exec.Command("unzip", "-o", "/tmp/xray.zip", "-d", filepath.Dir(dest)).Run()
	os.Chmod(dest, 0755)
	os.Remove("/tmp/xray.zip")
}

func generateXrayConfig(c Config) string {
	return fmt.Sprintf(`{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "127.0.0.1",
    "port": 10808,
    "protocol": "socks",
    "settings": {"udp": true}
  }],
  "outbounds": [{
    "protocol": "vless",
    "settings": {
      "vnext": [{
        "address": "%s",
        "port": %d,
        "users": [{
          "id": "%s",
          "encryption": "none",
          "flow": "xtls-rprx-vision"
        }]
      }]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "serverName": "%s",
        "fingerprint": "chrome",
        "publicKey": "%s",
        "shortId": "%s"
      }
    }
  }]
}`, c.Server, c.Port, c.UUID, c.SNI, c.PublicKey, c.ShortID)
}
