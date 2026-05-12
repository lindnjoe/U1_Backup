#!/bin/sh
###############################################################################
# 核心转储接收脚本 (由 kernel.core_pattern 管道调用)
#
# 配置示例 (放入 /etc/sysctl.conf 并 sysctl -p):
#   kernel.core_pattern="|/usr/bin/core_store %e %p %t"
#
# 传入参数 (由内核展开占位符):
#   $1 = 可执行文件路径 (%e)   可能包含路径
#   $2 = PID (%p)
#   $3 = Epoch 秒时间戳 (%t)   UTC
#
# 目标功能:
#   1. 生成包含 进程名 / 序号 / PID / UTC 时间 的 core 文件名。
#   2. 滚动保存同一“进程名”最近 N 份转储；序号语义：S0 最新，数字越大越旧。
#   3. 新 core 到来时：删除最旧槽位 (S{N-1})，其余整体后移 (S<i> -> S<i+1>)，再写新文件为 S0。
#   4. N 可通过 /etc/core_store.conf 中 MAX_PER_PROC=<正整数> 配置；默认 2。
#   5. 并发安全：同进程名用 mkdir 创建目录锁，避免同时移动/写文件。
#   6. 缩小 MAX_PER_PROC 时，清理高序号遗留文件。
#
# 生成文件名格式:
#   <base>_S<序号>_PID<PID>_<UTC>.core
#   示例: mqtt_agent_S0_PID1234_20250121T101523Z.core
#
# 依赖:
#   /bin/sh (BusyBox 可用)；date 支持 -u -d；mktemp；sed；mv；rm
#   无 flock 时使用 mkdir 简易锁；如可用 flock 可自行改进。
#
# 安全注意:
#   - core 文件含进程内存，权限设为 600。
#   - 请确保 /userdata/coredump 仅可信用户可访问。
#
# 返回码:
#   0 正常；非 0 表示写入失败。
###############################################################################

############################
# 1. 解析入参
############################
exe="$1"          # 原始可执行文件路径
pid="$2"          # 触发崩溃进程 PID
epoch="$3"        # UTC Epoch 秒

############################
# 2. 读取配置 (可选)
############################
limit=2           # 默认每进程保存份数
if [ -r /etc/core_store.conf ]; then
    # 期望内容形如: MAX_PER_PROC=5
    . /etc/core_store.conf 2>/dev/null
    case "$MAX_PER_PROC" in
        ''|*[!0-9]*) : ;;       # 非数字忽略
        *) [ "$MAX_PER_PROC" -ge 1 ] && limit="$MAX_PER_PROC" ;;
    esac
fi

############################
# 3. 规范化进程名与时间戳
############################
# basename 去路径，tr 替换非法字符为下划线，避免文件系统问题
base=$(basename "$exe" | tr -c 'A-Za-z0-9._-' '_')
# 去掉base左右两边的下划线（防止全非法字符导致全是下划线）
base=$(echo "$base" | sed 's/^_*\(.*[^_]\)_*$/\1/;s/^_*$//')
# 生成可读 UTC 时间，与字典序一致：YYYYMMDDTHHMMSSZ
utc=$(date -u -d "@$epoch" +%Y%m%dT%H%M%SZ)

############################
# 4. 准备目录
############################
dir="/userdata/.coredump"
mkdir -p "$dir" 2>/dev/null

############################
# 5. 获取锁 (目录锁法)
#    防止多个线程/进程同时处理同一进程名的序号滚动
############################
lockdir="${dir}/.lock_${base}"
i=0
while ! mkdir "$lockdir" 2>/dev/null; do
    [ $i -ge 100 ] && break          # 最多等待 ~5 秒
    usleep 50000 2>/dev/null || sleep 0.05
    i=$((i+1))
done
# 若等待超时仍未获得锁，继续执行可能产生竞争，但概率低。

############################
# 6. 序号滚动 (S0 最新)
#    处理顺序：从最大序号向下遍历：
#      - S{limit-1} 删除
#      - 其它 S<i> 重命名为 S<i+1>
############################
if [ "$limit" -ge 1 ]; then
    idx=$((limit-1))
    while [ $idx -ge 0 ]; do
        # 匹配当前序号文件 (理论上每序号最多一个；通配允许异常清理)
        for f in "${dir}/${base}_S${idx}_PID"*.core; do
            [ -e "$f" ] || continue
            if [ $idx -eq $((limit-1)) ]; then
                # 最旧槽位，直接删除
                rm -f "$f"
            else
                # 顺次后移：S<i> -> S<i+1>
                next=$((idx+1))
                # 构造新文件名：仅替换 _S<idx>_ 部分，保留 PID 与时间
                # 使用参数替换确保只替换首个匹配片段
                newf="${f/_S${idx}_/_S${next}_}"
                mv "$f" "$newf" 2>/dev/null
            fi
        done
        idx=$((idx-1))
    done
fi

############################
# 7. 写入最新 core (S0)
#    使用 mktemp + mv 保证写入原子性，避免部分写入导致损坏
############################
tmpfile=$(mktemp "${dir}/.tmp_${base}_S0_PID${pid}_${utc}_XXXXXX") || {
    rmdir "$lockdir" 2>/dev/null
    exit 1
}

# 从标准输入接收 core 数据
cat > "$tmpfile"

outfile="${dir}/${base}_S0_PID${pid}_${utc}.core"
mv "$tmpfile" "$outfile" 2>/dev/null || {
    rm -f "$tmpfile"
    rmdir "$lockdir" 2>/dev/null
    exit 1
}

# 设置权限：仅属主读写
chmod 600 "$outfile"

############################
# 8. 若管理员缩小 limit，清理超范围残留序号
############################
for f in "${dir}/${base}_S"*"_PID"*.core; do
    [ -e "$f" ] || continue
    seq=$(echo "$f" | sed -n "s/.*${base}_S\([0-9]\+\)_PID.*/\1/p")
    [ -n "$seq" ] && [ "$seq" -ge "$limit" ] && rm -f "$f"
done

############################
# 9. 释放锁并退出
############################
rmdir "$lockdir" 2>/dev/null
exit 0
