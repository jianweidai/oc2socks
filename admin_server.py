import os
import subprocess
from flask import Flask, request, jsonify, render_template

app = Flask(__name__)

# 持久化文件路径
TOKEN_FILE = "/data/vpn.token"

# 安全密钥，从环境变量获取
ADMIN_KEY = os.environ.get("ADMIN_KEY", "default_secret_key")

def check_vpn_status():
    """判断 VPN 是否在线：
    1. 检查 /sys/class/net/tunopen 接口是否存在
    2. 辅助检查 openconnect 进程是否存在
    """
    iface_exists = os.path.exists("/sys/class/net/tunopen")
    
    # 额外检查：有些系统可能没有 sysfs，回退到进程检查
    try:
        proc_check = subprocess.run(["pgrep", "openconnect"], capture_output=True)
        running = proc_check.returncode == 0
    except:
        running = iface_exists # 如果 pgrep 报错，就只信 iface

    return iface_exists and running

def get_current_token():
    """读取当前生效的 Token"""
    if os.path.exists(TOKEN_FILE):
        try:
            with open(TOKEN_FILE, "r") as f:
                return f.read().strip()
        except:
            pass
    return os.environ.get("VPN_PASSWORD", "")

def save_token(token):
    """保存 Token 到文件"""
    try:
        os.makedirs(os.path.dirname(TOKEN_FILE), exist_ok=True)
        with open(TOKEN_FILE, "w") as f:
            f.write(token.strip())
        return True
    except Exception as e:
        print(f"Error saving token: {e}")
        return False

@app.route('/')
def index():
    return "oc2socks Admin Server is running. Please access /admin?key=YOUR_KEY", 200

@app.route('/admin')
def admin_page():
    key = request.args.get('key')
    if key != ADMIN_KEY:
        return "Access Denied: Invalid Key", 403
    return render_template('index.html')

@app.route('/api/status')
def status_api():
    key = request.args.get('key')
    if key != ADMIN_KEY:
        return jsonify({"error": "unauthorized"}), 403
    
    token = get_current_token()
    # 脱敏处理：只显示前6位和后6位
    masked_token = "N/A"
    if token:
        masked_token = f"{token[:6]}...{token[-6:]}" if len(token) > 12 else token

    return jsonify({
        "online": check_vpn_status(),
        "vpn_server": os.environ.get("VPN_SERVER", "Unknown"),
        "masked_token": masked_token
    })

@app.route('/api/reconnect', methods=['POST'])
def reconnect_api():
    key = request.args.get('key')
    if key != ADMIN_KEY:
        return jsonify({"error": "unauthorized"}), 403
    
    data = request.json
    new_token = data.get('token')
    if not new_token:
        return jsonify({"error": "token required"}), 400

    save_token(new_token)

    try:
        # 尝试杀死可能存在的旧进程
        subprocess.run(["pkill", "openconnect"])
        
        vpn_server = os.environ.get('VPN_SERVER')
        user_agent = os.environ.get('VPN_USER_AGENT', 'AnyConnect Linux_64 4.7.00136')
        version = os.environ.get('VPN_VERSION_STRING', '4.7.00136')
        protocol = os.environ.get('VPN_PROTOCOL', 'anyconnect')

        cmd = f"echo '{new_token}' | openconnect -b --protocol={protocol} --cookie-on-stdin --useragent='{user_agent}' --version-string='{version}' --interface=tunopen --script=/vpnc-script-custom.sh {vpn_server}"
        subprocess.Popen(cmd, shell=True)
        # Wait for custom script to configure the interface
        subprocess.Popen("sleep 3 && echo 'VPN interface reconfigured'", shell=True)
        
        return jsonify({"message": "重连指令已发出，请稍后刷新。"})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/api/disconnect', methods=['POST'])
def disconnect_api():
    """断开 VPN 连接"""
    key = request.args.get('key')
    if key != ADMIN_KEY:
        return jsonify({"error": "unauthorized"}), 403
    
    try:
        # 杀死 openconnect 进程
        result = subprocess.run(["pkill", "openconnect"], capture_output=True)
        
        if result.returncode == 0:
            return jsonify({"message": "VPN 已断开连接。"})
        else:
            # pkill 返回非0可能是因为进程不存在
            if check_vpn_status():
                return jsonify({"error": "断开失败，请重试。"}), 500
            else:
                return jsonify({"message": "VPN 当前未连接。"})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/api/reconnect-last', methods=['POST'])
def reconnect_last_api():
    """使用上次保存的 Token 重新连接 VPN"""
    key = request.args.get('key')
    if key != ADMIN_KEY:
        return jsonify({"error": "unauthorized"}), 403
    
    # 获取已保存的 Token
    saved_token = get_current_token()
    if not saved_token:
        return jsonify({"error": "没有找到已保存的 Token，请手动输入。"}), 400

    try:
        # 尝试杀死可能存在的旧进程
        subprocess.run(["pkill", "openconnect"])
        
        vpn_server = os.environ.get('VPN_SERVER')
        user_agent = os.environ.get('VPN_USER_AGENT', 'AnyConnect Linux_64 4.7.00136')
        version = os.environ.get('VPN_VERSION_STRING', '4.7.00136')
        protocol = os.environ.get('VPN_PROTOCOL', 'anyconnect')

        cmd = f"echo '{saved_token}' | openconnect -b --protocol={protocol} --cookie-on-stdin --useragent='{user_agent}' --version-string='{version}' --interface=tunopen --script=/vpnc-script-custom.sh {vpn_server}"
        subprocess.Popen(cmd, shell=True)
        # Wait for custom script to configure the interface
        subprocess.Popen("sleep 3 && echo 'VPN interface reconfigured'", shell=True)
        
        return jsonify({"message": "正在使用上次的 Token 重连，请稍后刷新。"})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8989)
