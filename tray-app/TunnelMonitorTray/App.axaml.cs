using System.Diagnostics;
using System.IO;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Avalonia.Platform;
using Avalonia.Threading;

namespace TunnelMonitorTray;

public partial class App : Application
{
    private TrayIcon? _tray;
    private DispatcherTimer? _timer;
    private string _statePath = "";

    public override void Initialize()
    {
        AvaloniaXamlLoader.Load(this);
    }

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            desktop.ShutdownMode = ShutdownMode.OnExplicitShutdown;
        }

        _statePath = StatePathResolver.Resolve();
        _tray = CreateTray();
        _tray.IsVisible = true;

        _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
        _timer.Tick += (_, _) => UpdateTrayText();
        _timer.Start();

        UpdateTrayText();

        base.OnFrameworkInitializationCompleted();
    }

    private TrayIcon CreateTray()
    {
        Stream? iconStream = null;
        try
        {
            iconStream = AssetLoader.Open(new Uri("avares://TunnelMonitorTray/Assets/tray.png"));
        }
        catch
        {
            // ignore — menu still works
        }

        var menu = new NativeMenu();
        var refresh = new NativeMenuItem("Refresh");
        refresh.Click += (_, _) => UpdateTrayText();
        menu.Add(refresh);

        var openState = new NativeMenuItem("Open state folder");
        openState.Click += (_, _) => OpenContainingFolder(_statePath);
        menu.Add(openState);

        menu.Add(new NativeMenuItemSeparator());

        var quit = new NativeMenuItem("Quit");
        quit.Click += (_, _) =>
        {
            if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime d)
            {
                d.Shutdown();
            }
        };
        menu.Add(quit);

        WindowIcon? icon = null;
        if (iconStream is not null)
        {
            try
            {
                icon = new WindowIcon(iconStream);
            }
            catch
            {
                /* optional */
            }
        }

        return new TrayIcon
        {
            Icon = icon,
            ToolTipText = "Tunnel Monitor",
            Menu = menu
        };
    }

    private static void OpenContainingFolder(string path)
    {
        try
        {
            var dir = Path.GetDirectoryName(path);
            if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir))
            {
                return;
            }

            Process.Start(new ProcessStartInfo { FileName = dir, UseShellExecute = true });
        }
        catch
        {
            /* ignore */
        }
    }

    private void UpdateTrayText()
    {
        try
        {
            if (_tray is null)
            {
                return;
            }

            if (!File.Exists(_statePath))
            {
                _tray.ToolTipText = $"No state.json\n{_statePath}";
                return;
            }

            var json = File.ReadAllText(_statePath);
            var snap = JsonSerializer.Deserialize<MonitorSnapshot>(json, MonitorJson.Options);
            if (snap is null)
            {
                _tray.ToolTipText = "state.json unreadable";
                return;
            }

            var d = snap.EffectiveDedup;
            var r = d.reachable ? "reachable" : "unreachable";
            var st = string.IsNullOrEmpty(d.state) ? "?" : d.state!;
            var head = $"{snap.alert_state} — {(snap.diagnosis.Length > 100 ? snap.diagnosis[..100] + "…" : snap.diagnosis)}";
            _tray.ToolTipText = $"{head}\nDedup router: {r}, state={st}\n{_statePath}\n@{snap.timestamp}";
        }
        catch
        {
            if (_tray is not null)
            {
                _tray.ToolTipText = $"Read error:\n{_statePath}";
            }
        }
    }
}

internal static class StatePathResolver
{
    internal static string Resolve()
    {
        var envPath = Environment.GetEnvironmentVariable("TUNNEL_MONITOR_STATE");
        if (!string.IsNullOrWhiteSpace(envPath))
        {
            return envPath;
        }

        if (OperatingSystem.IsWindows())
        {
            var baseDir = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
            return Path.Combine(baseDir, "tunnel-monitor", "state.json");
        }

        return "/opt/tunnel-monitor/state.json";
    }
}

internal static class MonitorJson
{
    internal static readonly JsonSerializerOptions Options = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true
    };
}

internal sealed class MonitorSnapshot
{
    public string timestamp { get; set; } = "";
    public string alert_state { get; set; } = "?";
    public string diagnosis { get; set; } = "";

    public DedupBlockJson? router_dedup { get; set; }
    public DedupBlockJson? udr7_dedup { get; set; }

    public DedupBlockJson EffectiveDedup => udr7_dedup ?? router_dedup ?? new DedupBlockJson();
}

internal sealed class DedupBlockJson
{
    public bool reachable { get; set; }
    public string? state { get; set; }
    public string? checked_at { get; set; }
}
