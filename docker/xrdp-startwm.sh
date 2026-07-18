#!/bin/sh
# xrdp 容器定制启动脚本
# 加载系统 profile（locale、PATH 等环境变量）
if test -r /etc/profile; then
    . /etc/profile
fi

# 输入法环境变量必须在 startxfce4 之前导出，
# 否则 GTK/Qt 应用启动后无法切换出 fcitx5
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
export SDL_IM_MODULE=fcitx
export GLFW_IM_MODULE=ibus

# 启动 dbus 会话总线（XFCE/polkit/Thunar 依赖）
if command -v dbus-launch >/dev/null 2>&1; then
    eval "$(dbus-launch --sh-syntax --exit-with-session)"
    export DBUS_SESSION_BUS_ADDRESS DBUS_SESSION_BUS_PID
fi

# 启动 fcitx5 中文输入法（-d 后台 --replace 接管已有会话）
fcitx5 -d --replace >/dev/null 2>&1 &

# 启动 XFCE4 会话（xfwm4 窗口管理器 + xfce4-panel + xfdesktop 桌面图标）
exec startxfce4
