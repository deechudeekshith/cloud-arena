extends Node
class_name ServerConfig

## ServerConfig - Environment-based configuration for Cloud Arena
## Supports both local development (LAN) and production (cloud) environments

enum ServerEnvironment {
	DEVELOPMENT,  # Local testing - localhost/LAN
	PRODUCTION    # Cloud server - public internet
}

# Current environment - change this to switch between dev and prod
var current_environment: ServerEnvironment = ServerEnvironment.PRODUCTION

# Configuration structure
var config: Dictionary = {
	"environment": "development",
	"monitor_api": {
		"base_url": "http://127.0.0.1:8901",
		"use_https": false,
		"timeout": 10.0
	},
	"game_server": {
		"host": "127.0.0.1",
		"port": 7777,
		"use_wss": false,
		"connection_timeout": 15.0,
		"reconnect_attempts": 3,
		"reconnect_delay": 2.0
	},
	"room_discovery": {
		"enabled": true,  # LAN broadcast discovery
		"broadcast_port": 47777
	},
	"networking": {
		"max_players": 8,
		"tick_rate": 30,
		"compression_enabled": true
	}
}

func _ready() -> void:
	load_environment()

## Load configuration based on current environment
func load_environment() -> void:
	match current_environment:
		ServerEnvironment.DEVELOPMENT:
			load_development_config()
		ServerEnvironment.PRODUCTION:
			load_production_config()
	
	print("[ServerConfig] Loaded %s environment" % config.environment)
	print("[ServerConfig] Monitor API: %s" % config.monitor_api.base_url)
	print("[ServerConfig] Game Server: %s:%d" % [config.game_server.host, config.game_server.port])

## Development configuration (localhost/LAN)
func load_development_config() -> void:
	config = {
		"environment": "development",
		"monitor_api": {
			"base_url": "http://127.0.0.1:8901",
			"use_https": false,
			"timeout": 10.0
		},
		"game_server": {
			"host": "127.0.0.1",
			"port": 7777,
			"use_wss": false,
			"connection_timeout": 15.0,
			"reconnect_attempts": 3,
			"reconnect_delay": 2.0
		},
		"room_discovery": {
			"enabled": true,  # LAN broadcast enabled in dev
			"broadcast_port": 47777
		},
		"networking": {
			"max_players": 8,
			"tick_rate": 30,
			"compression_enabled": false  # Disabled for easier debugging
		}
	}

## Production configuration (cloud server - Render.com free tier)
## IMPORTANT: Replace YOUR_RENDER_APP_NAME with your actual Render app name after deployment
## Render provides: https://your-app-name.onrender.com
## Using WSS (Render provides automatic TLS certificates)
func load_production_config() -> void:
	# Read from environment variable if available (for easy configuration)
	var render_url = OS.get_environment("RENDER_URL")
	var server_host = "cloud-arena-server.onrender.com"  # UPDATE THIS after Render deployment
	var use_secure = true
	
	if render_url != "":
		# Extract host from RENDER_URL (format: https://app-name.onrender.com)
		server_host = render_url.replace("https://", "").replace("http://", "")
		print("[ServerConfig] Using RENDER_URL: %s" % server_host)
	
	config = {
		"environment": "production",
		"monitor_api": {
			"base_url": "https://%s" % server_host,  # Render provides HTTPS
			"use_https": use_secure,
			"timeout": 20.0
		},
		"game_server": {
			"host": server_host,  # Render app URL
			"port": 443,  # WSS uses port 443 (Render handles routing)
			"use_wss": use_secure,  # Use wss:// (Render provides TLS)
			"connection_timeout": 30.0,  # Longer timeout for cold starts
			"reconnect_attempts": 5,
			"reconnect_delay": 3.0
		},
		"room_discovery": {
			"enabled": false,  # LAN discovery disabled in production
			"broadcast_port": 47777
		},
		"networking": {
			"max_players": 8,
			"tick_rate": 30,
			"compression_enabled": true  # Enabled to reduce bandwidth
		}
	}

## Override production config with custom server address
## Call this before loading environment if you have server details
func set_production_server(server_host: String, server_port: int = 7777, use_https: bool = true) -> void:
	if current_environment == ServerEnvironment.PRODUCTION:
		config.game_server.host = server_host
		config.game_server.port = server_port
		config.game_server.use_wss = use_https
		
		var protocol = "https" if use_https else "http"
		config.monitor_api.base_url = "%s://%s:8901" % [protocol, server_host]
		config.monitor_api.use_https = use_https
		
		print("[ServerConfig] Production server updated: %s:%d" % [server_host, server_port])

## Get monitor API base URL
func get_monitor_url() -> String:
	return config.monitor_api.base_url

## Get game server WebSocket URL
func get_game_server_url() -> String:
	var protocol = "wss" if config.game_server.use_wss else "ws"
	return "%s://%s:%d" % [protocol, config.game_server.host, config.game_server.port]

## Check if running in development mode
func is_development() -> bool:
	return current_environment == ServerEnvironment.DEVELOPMENT

## Check if running in production mode
func is_production() -> bool:
	return current_environment == ServerEnvironment.PRODUCTION

## Check if LAN discovery is enabled
func is_lan_discovery_enabled() -> bool:
	return config.room_discovery.enabled

## Switch environment at runtime (useful for testing)
func switch_environment(env: ServerEnvironment) -> void:
	current_environment = env
	load_environment()

## Load environment from command line arguments or environment variables
## Usage: --environment=production or --server=1.2.3.4
func parse_launch_arguments() -> void:
	var args = OS.get_cmdline_args()
	
	for arg in args:
		if arg.begins_with("--environment="):
			var env_string = arg.split("=")[1].to_lower()
			if env_string == "production" or env_string == "prod":
				current_environment = ServerEnvironment.PRODUCTION
			elif env_string == "development" or env_string == "dev":
				current_environment = ServerEnvironment.DEVELOPMENT
		
		elif arg.begins_with("--server="):
			var server_host = arg.split("=")[1]
			if current_environment == ServerEnvironment.PRODUCTION:
				set_production_server(server_host)
	
	load_environment()

## Validate production configuration
## Returns true if production config has real server addresses (not placeholders)
func is_production_config_valid() -> bool:
	if current_environment != ServerEnvironment.PRODUCTION:
		return true  # Dev config always valid
	
	var has_placeholder = (
		config.game_server.host.contains("YOUR_VPS") or
		config.monitor_api.base_url.contains("YOUR_VPS") or
		config.game_server.host == "127.0.0.1" or
		config.game_server.host == "localhost"
	)
	
	return not has_placeholder

## Get human-readable validation message
func get_validation_message() -> String:
	if is_production_config_valid():
		return "Configuration valid for %s environment" % config.environment
	else:
		return "ERROR: Production configuration contains placeholder values. Update ServerConfig.gd with real VPS address before building production APK!"
