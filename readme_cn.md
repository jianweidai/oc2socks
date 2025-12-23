# oc2socks: 将 OpenConnect SSO 登录转换为 SOCKS5 代理

<p align="center">
<a href="https://github.com/Seey6/oc2socks/blob/main/readme.md">English</a> | <b>简体中文</b>
</p>

`oc2socks` 是一个 Docker化的工具，它可以将需要通过浏览器进行 SSO（单点登录）认证的 OpenConnect VPN 连接，无缝转换为一个本地 SOCKS5 代理。这使得您系统上的任何应用程序都能通过该代理连接到 VPN，而无需进行复杂的配置。

### ✨ 功能特性

  * **支持 SSO 登录**: 内置一个基于 Python 的 `sso-login-tool` 工具，可处理基于浏览器的 SSO 认证流程，并获取会话 Cookie。
  * **一键启动**: 获取令牌后，只需一条 `docker run` 命令即可运行整个代理服务。
  * **纯净隔离**: 采用 Docker 容器化技术，确保 VPN 的路由规则不会影响您主机的网络配置。
  * **预构建镜像**: 在 GitHub Container Registry (GHCR) 上提供了预构建的 Docker 镜像，方便快速部署。
  * **高度可配**: 通过环境变量支持自定义 VPN 协议、User-Agent 和 SOCKS 端口。

-----

## 🚀 使用教程

整个过程分为两个主要步骤：

1.  **获取会话令牌 (Session Token)**: 使用 `sso-login-tool` 工具通过浏览器认证并获取会话令牌。
2.  **运行 Docker 容器**: 使用获取到的令牌启动 `oc2socks` 容器。

### 第一步: 获取会话令牌

这个令牌将作为 OpenConnect 连接的一次性密码。

1.  **环境准备**: 确保您已安装 Python 3 和 `pip`。

2.  **安装依赖**: 克隆本项目仓库，并为登录工具安装所需的 Python 包。

    ```shell
    git clone https://github.com/seey6/oc2socks.git
    cd oc2socks/sso-login-tool
    pip install -r requirements.txt
    ```

3.  **运行登录脚本**: 执行 `cli.py` 脚本。它会自动打开一个浏览器窗口，让您完成 SSO 登录流程。

      * 请将 `vpn.sjsu.edu` 替换为您的 VPN 服务器地址。
      * 如果需要，请将 `Student-SSO` 替换为您的特定认证组。如果不需要，可以省略 `--authgroup` 参数。

    <!-- end list -->

    ```shell
    python ./cli.py --server vpn.sjsu.edu --authgroup Student-SSO
    ```

    登录成功后，脚本会在终端输出命令行和会话令牌。

4.  **复制会话令牌**: 这是最关键的一步。请复制标记为 **`Session Token`** 的长字符串。您将在下一步中将其用作 `VPN_PASSWORD`。

    ```text
    Command Line:  sudo openconnect --useragent ... --servercert ... https://vpn.sjsu.edu/
    Session Token:  ********@**********@******@********************** <- 复制这个值
    ```

### 第二步: 运行 oc2socks 容器

现在，使用刚刚获取的令牌来启动代理服务。

#### 方式一：使用预构建的 Docker 镜像 (推荐)

这是最简单快捷的方式。

1.  **拉取镜像**:

    ```shell
    docker pull ghcr.io/seey6/oc2socks
    ```

2.  **运行容器**:

    ```shell
    docker run -d --name oc2socks \
        --cap-add=NET_ADMIN \
        --device=/dev/net/tun \
        -p 1180:1180 \
        -e VPN_SERVER="vpn.sjsu.edu" \
        -e VPN_PASSWORD="<在这里粘贴你的会话令牌>" \
        ghcr.io/seey6/oc2socks
    ```

#### 方式二：从源码构建

如果您希望自定义工具，可以自己构建 Docker 镜像。

1.  **构建镜像**: 在项目根目录下，运行：

    ```shell
    docker build -t oc-socks-gateway .
    ```

2.  **运行容器**:

    ```shell
    docker run -d --name oc-socks \
        --cap-add=NET_ADMIN \
        --device=/dev/net/tun \
        -p 1180:1180 \
        -e VPN_SERVER="vpn.sjsu.edu" \
        -e VPN_PASSWORD="<在这里粘贴你的会话令牌>" \
        oc-socks-gateway
    ```

### 第三步: 配置您的 SOCKS5 代理

当容器成功运行后，一个 SOCKS5 代理就会在您的主机上可用。将您的应用程序或系统网络设置配置为使用此代理：

  * **代理服务器**: `127.0.0.1`
  * **端口**: `1180` (或您在 `docker run` 中映射的主机端口)
  * **类型**: SOCKS5

-----

### 🔧 环境变量

您可以通过以下环境变量自定义容器的行为:

| 变量名               | 描述                                           | 默认值                        |
| -------------------- | ---------------------------------------------- | ----------------------------- |
| `VPN_SERVER`         | **(必需)** 您的 VPN 服务器地址。               | (无)                          |
| `VPN_PASSWORD`       | **(必需)** 在第一步中获取的会话令牌。          | (无)                          |
| `SOCKS_PORT`         | 容器内 SOCKS5 代理使用的端口。                 | `1180`                        |
| `VPN_PROTOCOL`       | 使用的 VPN 协议 (例如 `anyconnect`, `gp`)。    | `anyconnect`                  |
| `VPN_USER_AGENT`     | OpenConnect 客户端的 User-Agent 字符串。       | `AnyConnect Linux_64 4.7.00136` |
| `VPN_VERSION_STRING` | OpenConnect 客户端的版本字符串。               | `4.7.00136`                   |

### 感谢
[openconnect-sso](https://github.com/vlaci/openconnect-sso)