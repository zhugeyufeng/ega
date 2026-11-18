#!/bin/bash

# 配置文件参数
SOURCE_DIR="/data2/PRJEB73794"                      # 源目录
DEST_DIRS=("/mnt/disk1" "/mnt/disk2" "/mnt/disk3")   # 目标硬盘路径
MAX_SIZE_TB=3                                        # 单个硬盘最大容量（TB）
LOG_FILE="$(dirname "$0")/rsync_transfer.log"        # 日志文件绝对路径
RSYNC_OPTS="-aP --no-owner --no-group"              # rsync参数：不更改所有者/组

# 初始化
MAX_SIZE_KB=$((MAX_SIZE_TB * 1024 * 1024 * 1024))    # 3TB = 3,221,225,472KB
declare -A dest_used                                  # 记录各目标目录已用空间（KB）

# 检查目录是否存在
check_dirs() {
    for dir in "$SOURCE_DIR" "${DEST_DIRS[@]}"; do
        if [ ! -d "$dir" ];then
            echo "[错误] 目录不存在: $dir" | tee -a "$LOG_FILE"
            exit 1
        fi
    done
}

# 检查目录权限
check_permissions() {
    echo "===== 检查目标目录权限 =====" | tee -a "$LOG_FILE"
    for dir in "${DEST_DIRS[@]}"; do
        if [ ! -w "$dir" ]; then
            echo "[警告] 目录 $dir 没有写入权限，尝试调整权限..." | tee -a "$LOG_FILE"
            touch "$dir/test_write_permission" 2>/dev/null
            if [ $? -ne 0 ]; then
                echo "[警告] 无法写入 $dir，将继续但可能会失败" | tee -a "$LOG_FILE"
            else
                rm "$dir/test_write_permission"
                echo "目录 $dir 有写入权限" | tee -a "$LOG_FILE"
            fi
        fi
    done
}

# 初始化目标目录已用空间
init_disk_usage() {
    echo "===== 检查目标硬盘空间 =====" | tee -a "$LOG_FILE"
    for dir in "${DEST_DIRS[@]}"; do
        # 检查目录已用空间
        if df -k "$dir" &>/dev/null; then
            current_usage_kb=$(df -k "$dir" | awk 'NR==2 {print $3}')
            dest_used["$dir"]=$current_usage_kb
            echo "硬盘 $dir 当前已用: $current_usage_kb KB" | tee -a "$LOG_FILE"
        else
            echo "[警告] 无法获取 $dir 的磁盘使用情况，假定为空" | tee -a "$LOG_FILE"
            dest_used["$dir"]=0
        fi
    done
}

# 按文件名自然排序获取文件列表（支持数字顺序）
get_sorted_files() {
    echo "===== 开始排序文件 =====" >> "$LOG_FILE"
    # 使用find+sort处理带空格和特殊字符的文件名，只将文件列表返回到标准输出
    find "$SOURCE_DIR" -maxdepth 1 -type f -printf "%f\n" | sort -V
    echo "文件排序完成" >> "$LOG_FILE"
}

# 动态分配文件到目标硬盘
transfer_files() {
    echo "===== 开始传输文件 =====" | tee -a "$LOG_FILE"
    local error_count=0
    
    for file in "${files[@]}"; do
        file_path="$SOURCE_DIR/$file"
        file_size_kb=$(du -k "$file_path" | awk '{print $1}')
        allocated=false
        
        # 检查文件大小是否超过单盘容量
        if (( file_size_kb > MAX_SIZE_KB )); then
            echo "[错误] 文件 $file 大小超过 ${MAX_SIZE_TB}T，无法存储" | tee -a "$LOG_FILE"
            (( error_count++ ))
            continue  # 跳过这个文件，继续处理下一个
        fi
        
        # 尝试次数
        local max_attempts=3
        local attempt=1
        
        # 轮询目标硬盘寻找可用空间
        for dest_dir in "${DEST_DIRS[@]}"; do
            if (( dest_used["$dest_dir"] + file_size_kb <= MAX_SIZE_KB )); then
                # 使用rsync执行断点续传，添加--no-owner --no-group选项
                echo "[$(date +'%Y-%m-%d %H:%M:%S')] 复制 $file → $dest_dir" | tee -a "$LOG_FILE"
                
                # 重试机制
                while [ $attempt -le $max_attempts ]; do
                    echo "  尝试 $attempt/$max_attempts..." | tee -a "$LOG_FILE"
                    rsync $RSYNC_OPTS -- "$file_path" "$dest_dir/" >> "$LOG_FILE" 2>&1
                    
                    if [ $? -eq 0 ]; then
                        dest_used["$dest_dir"]=$(( dest_used["$dest_dir"] + file_size_kb ))
                        allocated=true
                        break 2  # 成功，跳出两层循环
                    else
                        echo "[警告] rsync执行失败: $file → $dest_dir (尝试 $attempt/$max_attempts)" | tee -a "$LOG_FILE"
                        # 检查是否是权限问题
                        if grep -q "Permission denied\|Operation not permitted" "$LOG_FILE"; then
                            echo "  检测到权限问题，尝试更保守的rsync参数..." | tee -a "$LOG_FILE"
                            # 添加更多选项以避免权限问题
                            rsync -rlptD --progress -- "$file_path" "$dest_dir/" >> "$LOG_FILE" 2>&1
                            if [ $? -eq 0 ]; then
                                echo "  使用保守模式成功!" | tee -a "$LOG_FILE"
                                dest_used["$dest_dir"]=$(( dest_used["$dest_dir"] + file_size_kb ))
                                allocated=true
                                break 2  # 成功，跳出两层循环
                            fi
                        fi
                        
                        (( attempt++ ))
                        if [ $attempt -le $max_attempts ]; then
                            echo "  等待5秒后重试..." | tee -a "$LOG_FILE"
                            sleep 5
                        fi
                    fi
                done
                
                # 如果尝试了最大次数仍然失败，尝试下一个目录
                if [ "$allocated" = false ]; then
                    echo "[警告] 在 $dest_dir 上尝试 $max_attempts 次后失败，尝试下一个目录" | tee -a "$LOG_FILE"
                fi
            fi
        done
        
        # 分配失败处理
        if [ "$allocated" = false ]; then
            echo "[错误] 所有硬盘空间不足或传输失败，无法存储文件: $file" | tee -a "$LOG_FILE"
            (( error_count++ ))
            # 不退出，继续尝试下一个文件
        fi
    done
    
    # 返回错误计数，可用于主函数判断成功率
    return $error_count
}

# 打印汇总报告
print_summary() {
    echo "===== 传输完成 =====" | tee -a "$LOG_FILE"
    for dest_dir in "${DEST_DIRS[@]}"; do
        used_gb=$(echo "scale=2; ${dest_used["$dest_dir"]} / 1024 / 1024" | bc)
        echo "硬盘 $dest_dir 已使用: ${used_gb}GB" | tee -a "$LOG_FILE"
    done
    
    # 错误数量报告
    if [ $1 -gt 0 ]; then
        echo "总计 $1 个文件传输失败。详情请查看日志: $LOG_FILE" | tee -a "$LOG_FILE"
    else
        echo "所有文件传输成功！" | tee -a "$LOG_FILE"
    fi
}

# 主流程
main() {
    check_dirs
    check_permissions  # 新增权限检查
    init_disk_usage
    
    echo "获取文件列表..." | tee -a "$LOG_FILE"
    # 使用mapfile命令正确地捕获输出到数组
    mapfile -t files < <(get_sorted_files)
    
    # 打印找到的文件数量以便确认
    echo "找到 ${#files[@]} 个文件需要处理" | tee -a "$LOG_FILE"
    
    transfer_files
    error_count=$?
    
    print_summary $error_count
    
    # 返回总体状态
    if [ $error_count -gt 0 ]; then
        echo "警告: 有 $error_count 个文件传输失败" | tee -a "$LOG_FILE"
        exit 1
    else
        exit 0
    fi
}

main
