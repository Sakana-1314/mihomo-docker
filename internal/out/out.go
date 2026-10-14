// Package out 提供统一的进程输出（时间戳 + 级别前缀），与旧版脚本日志格式保持一致。
package out

import (
	"fmt"
	"os"
	"time"
)

func stamp() string {
	return time.Now().Format("2006-01-02 15:04:05")
}

// Logf 输出普通日志。
func Logf(format string, args ...any) {
	fmt.Fprintf(os.Stdout, "%s %s\n", stamp(), fmt.Sprintf(format, args...))
}

// Warnf 输出警告日志。
func Warnf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "%s [警告] %s\n", stamp(), fmt.Sprintf(format, args...))
}

// Errf 输出错误日志。
func Errf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "%s [错误] %s\n", stamp(), fmt.Sprintf(format, args...))
}
