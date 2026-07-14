# 网络PING/DNS（PD检测）检测工具

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-green.svg)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20macOS-blue.svg)](https://github.com/Cd1s/network-latency-tester)

强大的网络延迟检测工具，支持 Ping 测试、DNS 解析测试、综合分析等多种模式。

## ✨ 核心功能

- 🌐 **Ping 批量测试** - fping 快速检测延迟和丢包率
- 🔍 **DNS 性能测试** - 延迟、解析速度、智能评分（100分制）
- 🔄 **综合分析** - 一键完成延迟 + DNS 全面测试
- 🌍 **IPv4/IPv6 切换** - 灵活的网络协议优先级
- 📊 **彩色报告** - 实时进度、自动排序、结果保存

## 📥 快速开始

此处使用ba.sh短链
```bash
bash <(wget -qO- https://ba.sh/gZnH)
```

## 📋 测试网站

内置 **20 个**全球知名网站：Google、GitHub、Apple、Microsoft、AWS、Twitter、ChatGPT、Claude、Steam、NodeSeek、Netflix、Disney+、Instagram、Telegram、OneDrive、Twitch、Pornhub、YouTube、Facebook、TikTok

## 📊 延迟等级

| 等级 | 延迟 | 颜色 | 适用场景 |
|------|------|------|----------|
| 🟢 优秀 | < 50ms | 绿色 | 竞技游戏、实时通讯 |
| 🟡 良好 | 50-150ms | 黄色 | 网页浏览、视频播放 |
| 🔴 较差 | > 150ms | 红色 | 基础使用 |

## 🔧 依赖安装

`fping` 是快速批量测试使用的可选性能优化依赖；未安装时会跳过该加速阶段，后续测试自动回退到系统 `ping`，不会阻止启动。

**macOS**
```bash
brew install fping
```

**Ubuntu/Debian**
```bash
sudo apt install fping dnsutils curl
```

**CentOS/RHEL**
```bash
sudo yum install fping bind-utils curl
```

## 📄 许可证

MIT License - 详见 [LICENSE](LICENSE)

---

⭐ 如果对您有帮助，请给个 Star！
