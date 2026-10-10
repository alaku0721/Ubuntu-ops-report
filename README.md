# ops_report.sh
一个面向 Linux/WSL (Ubuntu) 的一键运维体检脚本，运行后以中文输出系统状态报告，方便日常巡检和排查问题。
功能
- 环境自检：自动判断是否运行在 Linux/WSL、是否具备 root/sudo 权限，并检查 ps、df、curl、docker、systemctl 等命令是否安装；缺失时给出安装命令，不再报一堆晦涩错误。
- 系统概览：显示主机名、发行版、内核版本、CPU 型号与核心数、运行时长、平均负载。
- 资源监控：查看内存使用概况与使用率，以及按内存/CPU 排序的 TOP 10 进程。
- 磁盘检查：查看文件系统容量、inode 使用率，并找出家目录下占用最大的目录。
- 网络与端口：列出网卡 IP、监听中的 TCP/UDP 端口和连接状态，支持 ss/netstat。
- 服务与日志：查看 systemd 运行中的服务、失败服务，以及本次启动以来的错误日志。
- Docker 容器：展示容器列表和资源占用快照。
- 连通性检测：用 curl 检测外网可达性和访问耗时。
环境要求
- Ubuntu（含 WSL2），bash 4+。
- 基础命令依赖：procps、coreutils、iproute2、curl。
- 可选组件：docker、systemd、net-tools，缺失时脚本会跳过对应模块并给出补齐方法。
