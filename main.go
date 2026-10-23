// Package main is the entry point for the 3x-ui web panel application.
// It initializes the database, web server, and handles command-line operations for managing the panel.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	_ "net/http/pprof"
	"os"
	"os/signal"
	"strings"
	"syscall"
	_ "unsafe"

	"github.com/mhsanaei/3x-ui/v3/internal/config"
	"github.com/mhsanaei/3x-ui/v3/internal/crypto/nodetoken"
	"github.com/mhsanaei/3x-ui/v3/internal/database"
	"github.com/mhsanaei/3x-ui/v3/internal/logger"
	"github.com/mhsanaei/3x-ui/v3/internal/sub"
	"github.com/mhsanaei/3x-ui/v3/internal/tunnelmonitor"
	"github.com/mhsanaei/3x-ui/v3/internal/util/crypto"
	"github.com/mhsanaei/3x-ui/v3/internal/util/sys"
	"github.com/mhsanaei/3x-ui/v3/internal/web"
	"github.com/mhsanaei/3x-ui/v3/internal/web/global"
	"github.com/mhsanaei/3x-ui/v3/internal/web/service"
	"github.com/mhsanaei/3x-ui/v3/internal/web/service/panel"
	"github.com/mhsanaei/3x-ui/v3/internal/web/service/tgbot"

	"github.com/joho/godotenv"
	"github.com/op/go-logging"
)

// cliFallbackTokenName is the single token the CLI regenerates, so `-getApiToken`
// cannot accumulate admin-equivalent credentials that are never revoked.
const cliFallbackTokenName = "cli-fallback"

// installTokenName is minted once on a panel with no tokens and is deliberately
// not the rotated slot, so the credential the installer recorded keeps working.
const installTokenName = "install"

// initNodeTokenCrypto loads the process codec, preferring the key file over
// the environment and failing closed when an enabled policy lacks a key.
func initNodeTokenCrypto() error {
	mode, err := nodetoken.ParseMode(config.GetNodeTokenEncryptionMode())
	if err != nil {
		return err
	}
	if mode == nodetoken.ModeOff {
		c, _ := nodetoken.NewCodec(nodetoken.ModeOff, nil)
		nodetoken.Init(c)
		return nil
	}
	ring, ferr := (nodetoken.FileKeySource{Path: config.GetNodeTokenKeyFile()}).Load()
	if ferr != nil {
		var eerr error
		if ring, eerr = (nodetoken.EnvKeySource{Var: config.GetNodeTokenKeyEnv()}).Load(); eerr != nil {
			return fmt.Errorf("加载节点令牌密钥失败：文件：%w；环境变量：%w", ferr, eerr)
		}
	}
	c, err := nodetoken.NewCodec(mode, ring)
	if err != nil {
		return err
	}
	nodetoken.Init(c)
	// The CLI runs before package logger initialization, so use log.Printf.
	log.Printf("节点令牌加密已启用（模式=%s，活动密钥=%s）", config.GetNodeTokenEncryptionMode(), c.ActiveKeyID())
	return nil
}

// runWebServer initializes and starts the web server for the 3x-ui panel.
func runWebServer() {
	log.Printf("正在启动 %v %v", config.GetName(), config.GetPanelVersion())

	switch config.GetLogLevel() {
	case config.Debug:
		logger.InitLogger(logging.DEBUG)
	case config.Info:
		logger.InitLogger(logging.INFO)
	case config.Notice:
		logger.InitLogger(logging.NOTICE)
	case config.Warning:
		logger.InitLogger(logging.WARNING)
	case config.Error:
		logger.InitLogger(logging.ERROR)
	default:
		log.Fatalf("未知日志级别：%v", config.GetLogLevel())
	}

	_ = godotenv.Load()

	for _, line := range sys.ApplyMemoryTuning() {
		logger.Info(line)
	}

	if os.Getenv("XUI_PPROF") == "true" {
		go func() {
			logger.Info("pprof 性能分析服务正在监听 127.0.0.1:6060")
			if err := http.ListenAndServe("127.0.0.1:6060", nil); err != nil {
				logger.Warning("pprof 服务已停止：", err)
			}
		}()
	}

	if err := initNodeTokenCrypto(); err != nil {
		log.Fatalf("初始化节点令牌加密失败：%v", err)
	}

	err := database.InitDB(config.GetDBPath())
	if err != nil {
		log.Fatalf("初始化数据库失败：%v", err)
	}

	server := web.NewServer()
	global.SetWebServer(server)
	err = server.Start()
	if err != nil {
		log.Fatalf("启动面板服务失败：%v", err)
	}

	sub.SetDistFS(web.EmbeddedDist())
	service.RegisterSubLinkProvider(sub.NewLinkProvider())
	subServer := sub.NewServer()
	global.SetSubServer(subServer)
	err = subServer.Start()
	if err != nil {
		log.Fatalf("启动订阅服务失败：%v", err)
	}

	sigCh := make(chan os.Signal, 8)
	// Trap shutdown signals
	signal.Notify(sigCh, syscall.SIGHUP, syscall.SIGTERM, sys.SIGUSR1, os.Interrupt)
	global.SetRestartHook(func() {
		select {
		case sigCh <- syscall.SIGHUP:
		default:
		}
	})

	var stopTunnelHealthMonitor context.CancelFunc
	monitorCfg := tunnelmonitor.ConfigFromEnv()
	if monitorCfg.Enabled {
		if monitorCfg.ProxyURL == "" {
			logger.Warning("隧道健康监控已启用，但未设置 XUI_TUNNEL_HEALTH_PROXY：探测检测的是主机连通性，而非 Xray 隧道；探测失败会重启 Xray，但无法修复主机网络问题。")
		}

		monitorCtx, cancel := context.WithCancel(context.Background())
		stopTunnelHealthMonitor = cancel

		monitor, err := tunnelmonitor.New(monitorCfg, func(_ context.Context) error {
			logger.Warning("隧道健康监控达到阈值，正在重启 xray-core。")
			return server.RestartXray()
		})
		if err != nil {
			logger.Warning("隧道健康监控已禁用：", err)
		} else {
			go monitor.Run(monitorCtx)
		}
	}
	for {
		sig := <-sigCh

		switch sig {
		case syscall.SIGHUP:
			logger.Info("收到 SIGHUP 信号，正在重启服务...")

			err := server.StopPanelOnly()
			if err != nil {
				logger.Debug("停止面板服务失败：", err)
			}
			err = subServer.Stop()
			if err != nil {
				logger.Debug("停止订阅服务失败：", err)
			}

			server = web.NewServer()
			global.SetWebServer(server)
			err = server.StartPanelOnly()
			if err != nil {
				log.Fatalf("重启面板服务失败：%v", err)
			}
			log.Println("面板服务重启成功。")

			sub.SetDistFS(web.EmbeddedDist())
			subServer = sub.NewServer()
			global.SetSubServer(subServer)
			err = subServer.Start()
			if err != nil {
				log.Fatalf("重启订阅服务失败：%v", err)
			}
			log.Println("订阅服务重启成功。")
		case sys.SIGUSR1:
			logger.Info("收到 USR1 信号，正在重启 xray-core...")
			err := server.RestartXray()
			if err != nil {
				logger.Error("重启 xray-core 失败：", err)
			}

		default:
			if stopTunnelHealthMonitor != nil {
				stopTunnelHealthMonitor()
			}

			// --- FIX FOR TELEGRAM BOT CONFLICT (409) on full shutdown ---
			tgbot.StopBot()
			// ------------------------------------------------------------

			if err := server.Stop(); err != nil {
				logger.Error("关闭服务失败：", err)
			}
			_ = subServer.Stop()
			log.Println("正在关闭服务。")
			return
		}
	}
}

// resetSetting resets all panel settings to their default values.
func resetSetting() error {
	err := database.InitDB(config.GetDBPath())
	if err != nil {
		fmt.Println("初始化数据库失败：", err)
		return err
	}

	settingService := service.SettingService{}
	err = settingService.ResetSettings()
	if err != nil {
		fmt.Println("重置设置失败：", err)
		return err
	} else {
		fmt.Println("设置已成功重置。")
	}
	return nil
}

// showSetting displays the current panel settings if show is true.
func showSetting(show bool) {
	if show {
		settingService := service.SettingService{}
		port, err := settingService.GetPort()
		if err != nil {
			fmt.Println("获取当前端口失败，错误信息：", err)
		}

		webBasePath, err := settingService.GetBasePath()
		if err != nil {
			fmt.Println("获取面板访问路径失败，错误信息：", err)
		}

		certFile, err := settingService.GetCertFile()
		if err != nil {
			fmt.Println("获取证书文件失败，错误信息：", err)
		}
		keyFile, err := settingService.GetKeyFile()
		if err != nil {
			fmt.Println("获取私钥文件失败，错误信息：", err)
		}

		userService := panel.UserService{}
		userModel, err := userService.GetFirstUser()
		if err != nil {
			fmt.Println("获取当前用户信息失败，错误信息：", err)
		}

		if userModel.Username == "" || userModel.Password == "" {
			fmt.Println("当前用户名或密码为空。")
		}

		fmt.Println("当前面板设置如下：")
		if certFile == "" || keyFile == "" {
			fmt.Println("警告：面板未配置 SSL 安全连接。")
		} else {
			fmt.Println("面板已启用 SSL 安全连接。")
		}

		hasDefaultCredential := func() bool {
			return userModel.Username == "admin" && crypto.CheckPasswordHash(userModel.Password, "admin")
		}()

		// 以下字段供安装及管理脚本解析，中文化时保留原始键名和布尔值。
		fmt.Println("hasDefaultCredential:", hasDefaultCredential)
		fmt.Println("port:", port)
		fmt.Println("webBasePath:", webBasePath)
	}
}

// updateTgbotEnableSts enables or disables the Telegram bot notifications based on the status parameter.
func updateTgbotEnableSts(status bool) {
	settingService := service.SettingService{}
	currentTgSts, err := settingService.GetTgbotEnabled()
	if err != nil {
		fmt.Println(err)
		return
	}
	logger.Infof("Telegram 通知当前启用状态［%v］，需要更新为［%v］", currentTgSts, status)
	if currentTgSts != status {
		err := settingService.SetTgbotEnabled(status)
		if err != nil {
			fmt.Println(err)
			return
		} else {
			logger.Infof("Telegram 通知启用状态已成功设为［%v］", status)
		}
	}
}

// updateTgbotSetting updates Telegram bot settings including token, chat ID, and runtime schedule.
func updateTgbotSetting(tgBotToken string, tgBotChatid string, tgBotRuntime string) {
	err := database.InitDB(config.GetDBPath())
	if err != nil {
		fmt.Println("初始化数据库失败：", err)
		return
	}

	settingService := service.SettingService{}

	if tgBotToken != "" {
		err := settingService.SetTgBotToken(tgBotToken)
		if err != nil {
			fmt.Printf("设置 Telegram 机器人令牌失败：%v\n", err)
			return
		}
		logger.Info("Telegram 机器人令牌更新成功。")
	}

	if tgBotRuntime != "" {
		err := settingService.SetTgbotRuntime(tgBotRuntime)
		if err != nil {
			fmt.Printf("设置 Telegram 机器人运行计划失败：%v\n", err)
			return
		}
		logger.Infof("Telegram 机器人运行计划已成功更新为［%s］。", tgBotRuntime)
	}

	if tgBotChatid != "" {
		err := settingService.SetTgBotChatId(tgBotChatid)
		if err != nil {
			fmt.Printf("设置 Telegram 机器人聊天 ID 失败：%v\n", err)
			return
		}
		logger.Info("Telegram 机器人聊天 ID 更新成功。")
	}
}

// encryptNodeTokens re-encrypts stored tokens after enablement or rotation.
// It requires migration|required mode and a configured key.
func encryptNodeTokens() {
	_ = godotenv.Load()
	if err := initNodeTokenCrypto(); err != nil {
		fmt.Println("初始化节点令牌加密失败：", err)
		os.Exit(1)
	}
	if err := database.InitDB(config.GetDBPath()); err != nil {
		fmt.Println("初始化数据库失败：", err)
		os.Exit(1)
	}
	changed, skipped, err := (&service.NodeService{}).MigrateNodeTokensToActiveKey()
	if err != nil {
		fmt.Println("令牌迁移失败：", err)
		os.Exit(1)
	}
	fmt.Printf("节点令牌迁移完成：%d 项已重新加密，%d 项已为当前版本或已跳过。\n", changed, skipped)
}

// updateSetting updates various panel settings including port, credentials, base path, listen IP, and two-factor authentication.
func updateSetting(port int, username string, password string, webBasePath string, listenIP string, resetTwoFactor bool) error {
	err := database.InitDB(config.GetDBPath())
	if err != nil {
		fmt.Println("初始化数据库失败：", err)
		return err
	}

	settingService := service.SettingService{}
	userService := panel.UserService{}

	if port > 0 {
		err := settingService.SetPort(port)
		if err != nil {
			fmt.Println("设置端口失败：", err)
		} else {
			fmt.Printf("端口设置成功：%v\n", port)
		}
	}

	if username != "" || password != "" {
		err := userService.UpdateFirstUser(username, password)
		if err != nil {
			fmt.Println("更新用户名和密码失败：", err)
		} else {
			fmt.Println("用户名和密码更新成功。")
		}
	}

	if webBasePath != "" {
		err := settingService.SetBasePath(webBasePath)
		if err != nil {
			fmt.Println("设置面板访问路径失败：", err)
		} else {
			fmt.Println("面板访问路径设置成功。")
		}
	}

	if resetTwoFactor {
		err := settingService.SetTwoFactorEnable(false)

		if err != nil {
			fmt.Println("重置双重验证失败：", err)
		} else {
			_ = settingService.SetTwoFactorToken("")
			fmt.Println("双重验证重置成功。")
		}
	}

	if listenIP != "" {
		err := settingService.SetListen(listenIP)
		if err != nil {
			fmt.Println("设置监听 IP 地址失败：", err)
		} else {
			fmt.Printf("监听 IP 地址已成功设为 %v。\n", listenIP)
		}
	}

	return nil
}

// updateCert updates the SSL certificate files for the panel.
func updateCert(publicKey string, privateKey string) {
	err := database.InitDB(config.GetDBPath())
	if err != nil {
		fmt.Println(err)
		return
	}

	if (privateKey != "" && publicKey != "") || (privateKey == "" && publicKey == "") {
		settingService := service.SettingService{}
		err = settingService.SetCertFile(publicKey)
		if err != nil {
			fmt.Println("设置证书公钥文件失败：", err)
		} else {
			fmt.Println("证书公钥文件设置成功。")
		}

		err = settingService.SetKeyFile(privateKey)
		if err != nil {
			fmt.Println("设置证书私钥文件失败：", err)
		} else {
			fmt.Println("证书私钥文件设置成功。")
		}

		err = settingService.SetSubCertFile(publicKey)
		if err != nil {
			fmt.Println("设置订阅证书公钥文件失败：", err)
		} else {
			fmt.Println("订阅证书公钥文件设置成功。")
		}

		err = settingService.SetSubKeyFile(privateKey)
		if err != nil {
			fmt.Println("设置订阅证书私钥文件失败：", err)
		} else {
			fmt.Println("订阅证书私钥文件设置成功。")
		}
	} else {
		fmt.Println("证书公钥和私钥文件必须同时提供，或同时留空。")
	}
}

// GetCertificate displays the current SSL certificate settings if getCert is true.
func GetCertificate(getCert bool) {
	if getCert {
		settingService := service.SettingService{}
		certFile, err := settingService.GetCertFile()
		if err != nil {
			fmt.Println("获取证书文件失败，错误信息：", err)
		}
		keyFile, err := settingService.GetKeyFile()
		if err != nil {
			fmt.Println("获取私钥文件失败，错误信息：", err)
		}

		fmt.Println("cert:", certFile)
		fmt.Println("key:", keyFile)
	}
}

// GetListenIP displays the current panel listen IP address if getListen is true.
func GetListenIP(getListen bool) {
	if getListen {

		settingService := service.SettingService{}
		ListenIP, err := settingService.GetListen()
		if err != nil {
			log.Printf("获取监听 IP 地址失败：%v", err)
			return
		}

		fmt.Println("listenIP:", ListenIP)
	}
}

func GetApiToken(getApiToken bool, tokenName, tokenScope string) {
	if !getApiToken {
		return
	}
	// An explicit name applies to both branches below; without one each keeps
	// the name it already used, so every existing invocation is unaffected.
	name := strings.TrimSpace(tokenName)
	err := database.InitDB(config.GetDBPath())
	if err != nil {
		fmt.Println("打开数据库失败，错误信息：", err)
		return
	}
	apiTokenService := panel.ApiTokenService{}
	tokens, err := apiTokenService.List()
	if err != nil {
		fmt.Println("获取 API 令牌失败，错误信息：", err)
		return
	}
	if len(tokens) > 0 {
		fmt.Printf("当前已配置 %d 个 API 令牌。系统仅保存哈希值，无法找回现有令牌的明文。\n", len(tokens))
		fmt.Println("如已丢失令牌，可通过面板中的“设置 -> API 令牌”管理并生成新令牌。")

		// Rotate one token per name so repeated calls cannot pile up
		// indefinitely many admin-equivalent tokens that never expire.
		rotated := name
		if rotated == "" {
			rotated = cliFallbackTokenName
		}
		created, err := apiTokenService.RecreateByName(rotated, tokenScope)
		if err != nil {
			fmt.Println("创建备用 API 令牌失败：", err)
			return
		}
		fmt.Printf("\nAPI 令牌 %q 已重新生成（此前的同名令牌现已失效）：\n", rotated)
		fmt.Println("apiToken:", created.Token)
		return
	}
	if name == "" {
		name = installTokenName
	}
	created, err := apiTokenService.Create(name, tokenScope, 0)
	if err != nil {
		fmt.Println("创建 API 令牌失败，错误信息：", err)
		return
	}
	fmt.Println("apiToken:", created.Token)
}

// migrateDb performs database migration operations for the 3x-ui panel.
func migrateDb() {
	inboundService := service.InboundService{}

	logger.InitLogger(logging.INFO)
	err := database.InitDB(config.GetDBPath())
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println("正在开始迁移数据库...")
	inboundService.MigrateDB()
	fmt.Println("迁移完成！")
}

// loadServiceEnvFile loads the systemd EnvironmentFile so CLI subcommands like
// "x-ui setting" hit the same database backend as the panel. godotenv.Load does
// not override variables already in the environment, so it is a no-op for the
// systemd-managed service.
func loadServiceEnvFile() {
	for _, path := range config.GetEnvFilePaths() {
		if _, err := os.Stat(path); err != nil {
			continue
		}
		if err := godotenv.Load(path); err != nil {
			log.Printf("警告：加载环境配置文件 %s 失败：%v", path, err)
		}
		return
	}
}

// main is the entry point of the 3x-ui application.
// It parses command-line arguments to run the web server, migrate database, or update settings.
func main() {
	loadServiceEnvFile()

	if len(os.Args) < 2 {
		runWebServer()
		return
	}

	var showVersion bool
	flag.BoolVar(&showVersion, "v", false, "显示版本")

	runCmd := flag.NewFlagSet("run", flag.ExitOnError)

	migrateDbCmd := flag.NewFlagSet("migrate-db", flag.ExitOnError)
	var migrateDsn string
	var migrateSrc string
	var migrateDump string
	var migrateRestore string
	var migrateOut string
	migrateDbCmd.StringVar(&migrateDsn, "dsn", "", "目标 PostgreSQL DSN（postgres://user:pass@host:port/db?sslmode=disable）")
	migrateDbCmd.StringVar(&migrateSrc, "src", "", "源 SQLite 文件（默认为当前配置的 x-ui.db）")
	migrateDbCmd.StringVar(&migrateDump, "dump", "", "将 --src 导出为可移植的 SQL 文本文件（.db -> .dump）")
	migrateDbCmd.StringVar(&migrateRestore, "restore", "", "从 SQL 文本文件重建 SQLite 数据库（.dump -> .db），必须指定 --out")
	migrateDbCmd.StringVar(&migrateOut, "out", "", "--restore 使用的目标 SQLite 文件（必须尚不存在）")

	settingCmd := flag.NewFlagSet("setting", flag.ExitOnError)
	var port int
	var username string
	var password string
	var webBasePath string
	var listenIP string
	var getListen bool
	var webCertFile string
	var webKeyFile string
	var tgbottoken string
	var tgbotchatid string
	var enabletgbot bool
	var tgbotRuntime string
	var reset bool
	var show bool
	var getCert bool
	var getApiToken bool
	var tokenName string
	var tokenScope string
	var resetTwoFactor bool
	settingCmd.BoolVar(&reset, "reset", false, "重置所有设置")
	settingCmd.BoolVar(&show, "show", false, "显示当前设置")
	settingCmd.IntVar(&port, "port", 0, "设置面板端口号")
	settingCmd.StringVar(&username, "username", "", "设置登录用户名")
	settingCmd.StringVar(&password, "password", "", "设置登录密码")
	settingCmd.StringVar(&webBasePath, "webBasePath", "", "设置面板访问路径")
	settingCmd.StringVar(&listenIP, "listenIP", "", "设置面板监听 IP 地址")
	settingCmd.BoolVar(&resetTwoFactor, "resetTwoFactor", false, "重置双重验证设置")
	settingCmd.BoolVar(&getListen, "getListen", false, "显示当前面板监听 IP 地址")
	settingCmd.BoolVar(&getCert, "getCert", false, "显示当前证书设置")
	settingCmd.BoolVar(&getApiToken, "getApiToken", false, "输出命令行使用的 API 令牌：重新生成并使旧令牌失效；面板尚无令牌时则创建新令牌")
	settingCmd.StringVar(&tokenName, "tokenName", "", "-getApiToken 操作的令牌名称（默认："+cliFallbackTokenName+"，或 "+installTokenName+"，在面板尚无令牌时使用）")
	settingCmd.StringVar(&tokenScope, "tokenScope", "", "-getApiToken 签发令牌的权限范围：admin、monitor 或 node-sync（默认继承被替换令牌的范围；新令牌默认为 admin）")
	settingCmd.StringVar(&webCertFile, "webCert", "", "设置面板证书公钥文件路径")
	settingCmd.StringVar(&webKeyFile, "webCertKey", "", "设置面板证书私钥文件路径")
	settingCmd.StringVar(&tgbottoken, "tgbottoken", "", "设置 Telegram 机器人令牌")
	settingCmd.StringVar(&tgbotRuntime, "tgbotRuntime", "", "设置 Telegram 机器人通知的 cron 时间")
	settingCmd.StringVar(&tgbotchatid, "tgbotchatid", "", "设置 Telegram 机器人通知的聊天 ID")
	settingCmd.BoolVar(&enabletgbot, "enabletgbot", false, "启用 Telegram 机器人通知")

	for _, command := range []*flag.FlagSet{runCmd, migrateDbCmd, settingCmd} {
		command.Usage = func() { printCLIUsage(command) }
	}
	flag.Usage = func() {
		printCLIUsage(flag.CommandLine)
		fmt.Fprint(flag.CommandLine.Output(), commandHelp())
	}

	flag.Parse()
	if showVersion {
		fmt.Println(config.GetPanelVersion())
		return
	}

	switch os.Args[1] {
	case "run":
		err := runCmd.Parse(os.Args[2:])
		if err != nil {
			fmt.Println(err)
			return
		}
		runWebServer()
	case "migrate":
		migrateDb()
	case "encrypt-tokens":
		encryptNodeTokens()
	case "migrate-db":
		if err := migrateDbCmd.Parse(os.Args[2:]); err != nil {
			fmt.Println(err)
			return
		}
		src := migrateSrc
		if src == "" {
			src = config.GetDBPath()
		}
		switch {
		case migrateDump != "":
			if err := database.DumpSQLite(src, migrateDump); err != nil {
				fmt.Println("导出失败：", err)
				os.Exit(1)
			}
			fmt.Printf("已导出 %s -> %s\n", src, migrateDump)
		case migrateRestore != "":
			if migrateOut == "" {
				fmt.Println("使用 --restore 时必须指定 --out：目标 .db 文件路径（必须尚不存在）")
				return
			}
			if err := database.RestoreSQLite(migrateRestore, migrateOut); err != nil {
				fmt.Println("恢复失败：", err)
				os.Exit(1)
			}
			fmt.Printf("已恢复 %s -> %s\n", migrateRestore, migrateOut)
		case migrateDsn != "":
			if err := database.MigrateData(src, migrateDsn); err != nil {
				fmt.Println("迁移失败：", err)
				os.Exit(1)
			}
		default:
			fmt.Println("未指定操作：请传入 --dump <file>、--restore <file> --out <db>，或 --dsn <postgres-dsn>")
		}
	case "setting":
		err := settingCmd.Parse(os.Args[2:])
		if err != nil {
			fmt.Println(err)
			return
		}
		// flag stops parsing at the first non-flag argument, so the `-getApiToken true`
		// form drops every flag written after it. Say so instead of acting on a default.
		if rest := settingCmd.Args(); len(rest) > 0 {
			fmt.Printf("警告：已忽略 %q 及其后的所有选项；请将选项放在位置参数之前。\n", strings.Join(rest, " "))
		}
		if reset {
			if err = resetSetting(); err != nil {
				return
			}
		} else {
			if err = updateSetting(port, username, password, webBasePath, listenIP, resetTwoFactor); err != nil {
				return
			}
		}
		if webCertFile != "" || webKeyFile != "" {
			updateCert(webCertFile, webKeyFile)
		}
		if show {
			showSetting(show)
		}
		if getListen {
			GetListenIP(getListen)
		}
		if getCert {
			GetCertificate(getCert)
		}
		if getApiToken {
			GetApiToken(getApiToken, tokenName, tokenScope)
		}
		if (tgbottoken != "") || (tgbotchatid != "") || (tgbotRuntime != "") {
			updateTgbotSetting(tgbottoken, tgbotchatid, tgbotRuntime)
		}
		if enabletgbot {
			updateTgbotEnableSts(enabletgbot)
		}
	case "cert":
		err := settingCmd.Parse(os.Args[2:])
		if err != nil {
			fmt.Println(err)
			return
		}
		if reset {
			updateCert("", "")
		} else {
			updateCert(webCertFile, webKeyFile)
		}
	default:
		fmt.Println("无效的子命令")
		fmt.Println()
		runCmd.Usage()
		fmt.Println()
		settingCmd.Usage()
	}
}

func commandHelp() string {
	return `
命令：
    run            运行面板服务
    migrate        从其他或旧版 x-ui 迁移
    migrate-db     SQLite <-> .dump（--dump/--restore），或复制至 PostgreSQL（--dsn）
    encrypt-tokens 使用已配置的活动密钥加密节点令牌
    setting        修改或查看面板设置
    cert           设置或清除面板证书
`
}

// 中文帮助仅替换展示标题，保留 flag 包的参数名称、默认值和退出行为。
func printCLIUsage(command *flag.FlagSet) {
	fmt.Fprintf(command.Output(), "用法：%s [选项]\n", command.Name())
	command.PrintDefaults()
}
