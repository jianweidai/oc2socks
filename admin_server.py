import os
import subprocess
from flask import Flask, request, jsonify, render_template

app = Flask(__name__)

# 持久化文件路径
TOKEN_FILE = "/data/vpn.token"

# 安全密钥，从环境变量获取
ADMIN_KEY = os.environ.get("ADMIN_KEY", "default_secret_key")

def check_vpn_status():
    """通过检查 tunopen 网络接口判断 VPN 是否在线"""
    try:
        result = subprocess.run(["ip", "addr", "show", "tunopen"], capture_output=True, text=True)
        return result.returncode == 0
    except:
        return False

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

        cmd = f"echo '{new_token}' | openconnect -b --protocol={protocol} --cookie-on-stdin --useragent='{user_agent}' --version-string='{version}' --interface=tunopen {vpn_server}"
        subprocess.Popen(cmd, shell=True)
        
        return jsonify({"message": "重连指令已发出，请稍后刷新。"})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8989)
