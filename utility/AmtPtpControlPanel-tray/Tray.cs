using System;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Win32;

namespace AmtPtpControlPanel
{
    // Tray integration:
    //  - system tray icon, optional battery readout (driver IOCTL, overlapped I/O)
    //  - "Start with Windows" toggle (elevated logon scheduled task "MagicTrackpad",
    //    so no UAC prompt appears at logon)
    //  - "Start minimized" toggle (autostart uses the -minimized argument;
    //    launching the app with -minimized hides it in the tray)
    public partial class Main : Form
    {
        private const string TRAY_REG_PATH = @"Software\MtTrackpad\Tray";

        private NotifyIcon trayIcon;
        private ToolStripMenuItem miBatteryItem;
        private ToolStripMenuItem miShowBattery;
        private ToolStripMenuItem miAutoStart;
        private ToolStripMenuItem miStartMin;
        private ToolStripMenuItem miRotation;
        private System.Collections.Generic.Dictionary<int, ToolStripMenuItem> rotationItems;
        private System.Windows.Forms.Timer trayTimer;
        private int lastBatteryPercent = -1;
        private System.DateTime lastUiRefresh = System.DateTime.MinValue;
        private System.Windows.Forms.Timer earlyUiTimer;
        private int earlyUiTicks;
        // Battery polling is strictly on demand: the timer only runs while the
        // settings window is actually being looked at (focused/restored). When
        // the app sits in the tray there is NO polling at all - that way the
        // app can never keep the trackpad or its radio busy and drain anything.
        // Opening the tray menu or the window reads immediately instead.
        private const int BatteryPollIntervalMs = 5000;
        private bool hiddenOnStartup = false;
        private bool trayExitRequested = false;
        private int trayCloseCount = 0;
        private bool hidingToTray = false;
        private bool trayHideBalloonShown = false;
        private System.Windows.Forms.ToolTip tipOptions;
        private Icon iconBase16;
        private Icon iconNa;
        // second launches signal this event so the running instance
        // brings its window up instead of exiting silently
        private System.Threading.EventWaitHandle showEvent;
        // one icon per percentage value actually reported: the tray icon
        // carries the literal number so the level is visible even where
        // Windows 11 hides the text next to tray icons
        private System.Collections.Generic.Dictionary<int, Icon> iconByPercent;

        private void TrayWire(string[] args)
        {
            WireControlTooltips();
            BuildForceClickUi();
            BuildRotationUi();

            try
            {
                this.Icon = LoadEmbeddedIcon(32);
            }
            catch
            {
            }

            if (args != null)
                foreach (string a in args)
                    if (a == "-minimized" || a == "-hidden")
                        hiddenOnStartup = true;

            this.Load += (s, e) => InitTray();

            // Minimizing must not leave a taskbar card behind: fold the window
            // away into the tray icon instead.
            this.Resize += (s, e) =>
            {
                if (WindowState == FormWindowState.Minimized)
                    HideToTray(true);
            };

            this.FormClosing += (s, e) =>
            {
                try
                {
                    if (trayIcon == null || trayExitRequested)
                        return;

                    // "Start hidden in system tray" means this is a tray app:
                    // the X button only hides it, quitting is the icon menu's job
                    if (SettingStartMin)
                    {
                        HideToTray(true);
                        e.Cancel = true;
                        return;
                    }

                    trayCloseCount += 1;
                    if (trayCloseCount == 1)
                    {
                        // first close: park in the tray instead of quitting
                        HideToTray(true);
                        e.Cancel = true;
                    }
                }
                catch
                {
                }
            };
            this.FormClosed += (s, e) => DisposeTray();
            // focusing the window (any way the user opens it) forces a
            // fresh battery read; the same-UI-thread WinForms timer means
            // this can never race with the 5 s background refresh
            this.Activated += (s, e) =>
            {
                // the user is looking at the app: poll while that lasts and
                // read once right away
                RefreshForceClickStatus();
                RefreshRotationChecks();
                RefreshRotationStatus();
                StartBatteryPolling();
                if ((System.DateTime.Now - lastUiRefresh)
                        .TotalMilliseconds > 1000)
                {
                    lastUiRefresh = System.DateTime.Now;
                    RefreshTray();
                }
            };
            // not being watched any more: stop polling completely (no battery
            // reads, no driver traffic, no power draw while it sits in the tray)
            this.Deactivate += (s, e) => StopBatteryPolling();
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            if (hiddenOnStartup)
            {
                WindowState = FormWindowState.Minimized;
                ShowInTaskbar = false;
                Visible = false;
                try
                {
                    if (trayIcon != null)
                    {
                        trayIcon.Visible = true;
                        trayIcon.BalloonTipTitle = "Magic Trackpad";
                        trayIcon.BalloonTipText = "Running in the system tray.";
                        trayIcon.ShowBalloonTip(3000);
                    }
                }
                catch
                {
                }
            }
            // opening the settings window always triggers an immediate battery
            // read, so the number, the menu line and the icon are fresh the
            // moment the UI comes up (not just at the next 5 s tick)
            lastUiRefresh = System.DateTime.MinValue;
            RefreshTray();
        }

        //=================
        // Registry helpers
        //=================

        private static int TrayGetInt(string name, int def)
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(TRAY_REG_PATH))
                {
                    if (key != null)
                    {
                        object v = key.GetValue(name);
                        if (v is int)
                            return (int)v;
                    }
                }
            }
            catch
            {
            }
            return def;
        }

        private static void TraySetInt(string name, int value)
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.CreateSubKey(TRAY_REG_PATH))
                    key.SetValue(name, value, RegistryValueKind.DWord);
            }
            catch
            {
            }
        }

        private bool SettingShowBattery { get { return TrayGetInt("ShowBattery", 1) != 0; } }
        private bool SettingAutoStart { get { return TrayGetInt("AutoStart", 0) != 0; } }
        private bool SettingStartMin { get { return TrayGetInt("StartMin", 0) != 0; } }

        //=================
        // Tray setup
        //=================

        private void InitTray()
        {
            try
            {
                miBatteryItem = new ToolStripMenuItem("Battery: ...");
                miBatteryItem.Enabled = false;
                miBatteryItem.ToolTipText =
                    "Charge of the trackpad's built-in battery, read from the driver " +
                    "every 5 seconds. The driver only reports the battery when " +
                    "the trackpad is connected via Bluetooth; with a USB connection " +
                    "this line shows 'not available'. The app must run elevated " +
                    "(admin), otherwise the driver's battery port cannot be opened.";

                miShowBattery = new ToolStripMenuItem("Show battery percentage in tray");
                miShowBattery.Checked = SettingShowBattery;
                miShowBattery.CheckOnClick = true;
                miShowBattery.ToolTipText =
                    "When on, the tray icon changes with the charge level (green " +
                    "full, amber medium, red low) and the exact percentage shows in " +
                    "this menu and in the icon's hover text, refreshed every 5 " +
                    "seconds. Bluetooth mode only: in USB mode the driver exposes " +
                    "no level and the icon shows a gray question mark. Same switch " +
                    "exists in the settings window (Battery group).";
                miShowBattery.Click += (s, e) =>
                {
                    TraySetInt("ShowBattery", miShowBattery.Checked ? 1 : 0);
                    ctlShowBatteryInTray.Checked = miShowBattery.Checked;
                    RefreshTray();
                };

                miAutoStart = new ToolStripMenuItem("Start with Windows");
                miAutoStart.Checked = SettingAutoStart;
                miAutoStart.ToolTipText =
                    "Registers an elevated logon task for the current user - no UAC " +
                    "prompt at login, so the tray icon always comes up even when " +
                    "nobody is there to click a prompt. Settings are per-user; the " +
                    "elevated copy uses your usual user profile.";
                miAutoStart.Click += (s, e) =>
                {
                    TraySetInt("AutoStart", miAutoStart.Checked ? 1 : 0);
                    ctlStartAuto.Checked = miAutoStart.Checked;
                    WriteAutoStart();
                };

                miStartMin = new ToolStripMenuItem("Start minimized");
                miStartMin.Checked = SettingStartMin;
                miStartMin.ToolTipText =
                    "Only relevant together with 'Start with Windows': at login the " +
                    "app appears as a tray icon only - no window pops up. Double-click " +
                    "the tray icon (or use 'Open') to bring up the settings window. " +
                    "If the app is started by hand this option has no effect.";
                miStartMin.Click += (s, e) =>
                {
                    TraySetInt("StartMin", miStartMin.Checked ? 1 : 0);
                    ctlStartHidden.Checked = miStartMin.Checked;
                    WriteAutoStart();
                };

                miRotation = new ToolStripMenuItem("Rotation");
                miRotation.ToolTipText =
                    "Rotates the trackpad input in 90 degree steps. The driver re-reads " +
                    "the setting when the device restarts, so the trackpad blinks once. " +
                    "Needs a driver built with rotation support - the Microsoft-signed " +
                    "one predates it and ignores the option.";
                BuildRotationMenu();

                ToolStripMenuItem miOpen = new ToolStripMenuItem("Open");
                miOpen.ToolTipText = "Brings up the main settings window.";
                miOpen.Click += (s, e) => RestoreFromTray();

                ToolStripMenuItem miExit = new ToolStripMenuItem("Exit");
                miExit.ToolTipText =
                    "Stops the app and removes the tray icon. Your options are saved " +
                    "in the user registry, so they survive restarts.";
                miExit.Click += (s, e) =>
                {
                    trayExitRequested = true;
                    DisposeTray();
                    Close();
                };

                ContextMenuStrip trayMenu = new ContextMenuStrip();
                // the menu always shows a value read right now, which is why
                // the background cadence can be slow while unfocused
                trayMenu.Opening += (s, e) =>
                {
                    RefreshTray();
                    RefreshRotationChecks();
                };
                trayMenu.Items.Add(miBatteryItem);
                trayMenu.Items.Add(new ToolStripSeparator());
                trayMenu.Items.Add(miShowBattery);
                trayMenu.Items.Add(miAutoStart);
                trayMenu.Items.Add(miStartMin);
                trayMenu.Items.Add(miRotation);
                trayMenu.Items.Add(new ToolStripSeparator());
                trayMenu.Items.Add(miOpen);
                trayMenu.Items.Add(miExit);

                // settings-window twin of the menu option (bidirectional sync)
                ctlShowBatteryInTray.Checked = SettingShowBattery;
                ctlShowBatteryInTray.CheckedChanged += (s, e) =>
                {
                    TraySetInt("ShowBattery", ctlShowBatteryInTray.Checked ? 1 : 0);
                    miShowBattery.Checked = ctlShowBatteryInTray.Checked;
                    RefreshTray();
                };

                ctlStartAuto.Checked = SettingAutoStart;
                ctlStartAuto.CheckedChanged += (s, e) =>
                {
                    TraySetInt("AutoStart", ctlStartAuto.Checked ? 1 : 0);
                    miAutoStart.Checked = ctlStartAuto.Checked;
                    WriteAutoStart();
                };

                ctlStartHidden.Checked = SettingStartMin;
                ctlStartHidden.CheckedChanged += (s, e) =>
                {
                    TraySetInt("StartMin", ctlStartHidden.Checked ? 1 : 0);
                    miStartMin.Checked = ctlStartHidden.Checked;
                    WriteAutoStart();
                };

                BuildBatteryIcons();

                trayIcon = new NotifyIcon();
                trayIcon.Icon = iconBase16 != null ? iconBase16 : LoadEmbeddedIcon(16);
                trayIcon.Text = "Magic Trackpad";
                trayIcon.ContextMenuStrip = trayMenu;
                trayIcon.DoubleClick += (s, e) => RestoreFromTray();
                trayIcon.Visible = true;

                trayTimer = new System.Windows.Forms.Timer();
                trayTimer.Interval = BatteryPollIntervalMs;
                trayTimer.Tick += (s, e) => RefreshTray();
                if (!hiddenOnStartup)
                    trayTimer.Start();   // only while the window is watched

                RefreshTray();
                StartShowListener();

                // right after launch the device sometimes does not answer
                // yet (driver start-up, UAC relay hand-over), so a single
                // initial read would leave "Battery: ..." for up to 5 s;
                // force fresh reads at 1, 2 and 3 seconds after launch
                earlyUiTicks = 0;
                earlyUiTimer = new System.Windows.Forms.Timer();
                earlyUiTimer.Interval = 1000;
                earlyUiTimer.Tick += (s, e) =>
                {
                    earlyUiTicks++;
                    RefreshTray();
                    if (earlyUiTicks >= 3)
                    {
                        earlyUiTimer.Stop();
                        earlyUiTimer.Dispose();
                        earlyUiTimer = null;
                    }
                };
                earlyUiTimer.Start();

                // one-time migration off the old HKCU Run entry
                MigrateAutoStart();
            }
            catch
            {
                DisposeTray();
            }
        }

        private void DisposeTray()
        {
            try
            {
                if (trayTimer != null)
                {
                    trayTimer.Stop();
                    trayTimer.Dispose();
                    trayTimer = null;
                }
                if (trayIcon != null)
                {
                    trayIcon.Visible = false;
                    trayIcon.Dispose();
                    trayIcon = null;
                }
                if (showEvent != null)
                {
                    showEvent.Close();
                    showEvent = null;
                }
                if (forceClickEvent != null)
                {
                    forceClickEvent.Close();
                    forceClickEvent = null;
                }
                if (tipOptions != null)
                {
                    tipOptions.Dispose();
                    tipOptions = null;
                }
            }
            catch
            {
            }
        }

        private void RestoreFromTray()
        {
            try
            {
                Show();
                WindowState = FormWindowState.Normal;
                ShowInTaskbar = true;
                Activate();
                // the window is about to be looked at: read once and poll while
                // it stays in the foreground
                lastUiRefresh = System.DateTime.MinValue;
                RefreshTray();
                StartBatteryPolling();
            }
            catch
            {
            }
        }

        // A second launch (double-clicking the shortcut again, or clicking a
        // pinned icon) sets the show event; this thread marshals that onto the
        // UI thread and restores the window. Without it the second process just
        // exits and the user sees "nothing happen".
        private void StartShowListener()
        {
            try
            {
                showEvent = new System.Threading.EventWaitHandle(false,
                    System.Threading.EventResetMode.AutoReset,
                    TrayLaunch.SHOW_EVENT_NAME);
                System.Threading.Thread t = new System.Threading.Thread(delegate()
                {
                    while (true)
                    {
                        try
                        {
                            if (!showEvent.WaitOne(2000))
                                continue;
                            try
                            {
                                this.BeginInvoke((MethodInvoker)delegate()
                                {
                                    RestoreFromTray();
                                });
                            }
                            catch
                            {
                            }
                        }
                        catch
                        {
                        }
                    }
                });
                t.IsBackground = true;
                t.Name = "mt-show-listener";
                t.Start();
            }
            catch
            {
            }
        }

        // Hides the window in the tray: no taskbar card, no polling, only the
        // notification-area icon remains. Used by the minimize button, by the
        // close button and when the app starts hidden.
        private void HideToTray(bool showBalloon)
        {
            try
            {
                if (hidingToTray)
                    return;
                hidingToTray = true;
                WindowState = FormWindowState.Minimized;
                ShowInTaskbar = false;
                Visible = false;
                StopBatteryPolling();
                if (showBalloon && trayIcon != null && !trayHideBalloonShown)
                {
                    trayHideBalloonShown = true;
                    trayIcon.BalloonTipTitle = "Magic Trackpad";
                    trayIcon.BalloonTipText = SettingStartMin
                        ? "The window is hidden - this app lives in the tray icon (right-click it). Use 'Exit' there to quit."
                        : "The window is hidden - the app keeps running in the tray icon (right-click it). Use 'Exit' there to quit, or start the app again to bring the window back.";
                    trayIcon.ShowBalloonTip(5000);
                }
            }
            catch
            {
            }
            finally
            {
                hidingToTray = false;
            }
        }

        private void StartBatteryPolling()
        {
            try
            {
                if (trayTimer != null && !trayTimer.Enabled)
                    trayTimer.Start();
            }
            catch
            {
            }
        }

        private void StopBatteryPolling()
        {
            try
            {
                if (trayTimer != null && trayTimer.Enabled)
                    trayTimer.Stop();
            }
            catch
            {
            }
        }

        private void RefreshTray()
        {
            if (trayIcon == null)
                return;

            try
            {
                if (SettingShowBattery)
                {
                    int percent;
                    if (TrayBattery.TryGetBattery(out percent))
                        lastBatteryPercent = percent;

                    if (lastBatteryPercent >= 0)
                    {
                        miBatteryItem.Text = "Battery: " + lastBatteryPercent + " %";
                        // the toggle item carries the live number too, so the
                        // "Show battery percentage in tray" wording is always
                        // followed by the value
                        miShowBattery.Text = "Show battery percentage in tray - "
                                + lastBatteryPercent + " %";
                        // the icon is the number itself
                        if (PickBatteryIcon(lastBatteryPercent) != null)
                            trayIcon.Icon = PickBatteryIcon(lastBatteryPercent);
                        // short Text on purpose: on Windows 11 this string is
                        // what the tray shows NEXT TO the icon once the icon's
                        // "show label" option is enabled
                        trayIcon.Text = lastBatteryPercent + "%";
                    }
                    else
                    {
                        miBatteryItem.Text = "Battery: not available";
                        miShowBattery.Text = "Show battery percentage in tray - "
                                + "no reading (USB mode)";
                        if (iconNa != null)
                            trayIcon.Icon = iconNa;
                        trayIcon.Text = "no reading";
                    }
                }
                else
                {
                    miBatteryItem.Text = "Battery: off";
                    miShowBattery.Text = "Show battery percentage in tray";
                    if (iconBase16 != null)
                        trayIcon.Icon = iconBase16;
                    trayIcon.Text = "Magic Trackpad";
                }
            }
            catch
            {
            }
        }

        // Battery glyph with the actual percentage drawn inside the cell:
        // green (>= 50 %), amber (>= 25 %), red (below). The per-percent
        // icons are built lazily and cached; at most a handful exist per
        // process lifetime, so the small native-handle cost is accepted
        // (icons are never destroyed - see the note on MakeBatteryIcon).
        private Icon PickBatteryIcon(int pct)
        {
            Icon cached;
            if (iconByPercent == null)
                iconByPercent = new System.Collections.Generic.Dictionary<int, Icon>();
            if (iconByPercent.TryGetValue(pct, out cached))
                return cached;

            // the digits are the icon: bright level-colored number on top,
            // a charge-level bar across the bottom of the 16 px tile
            Color fill = LevelColor(pct);
            Color digit = DigitColor(pct);

            Icon built = MakeBatteryIcon(pct / 100f, fill,
                Color.FromArgb(235, 235, 235), pct.ToString(), digit);
            if (built != null)
                iconByPercent[pct] = built;
            return built;
        }

        // shared level palette: the tray icon, the on-screen readout and the
        // tooltip all use the same colours
        private static Color LevelColor(int pct)
        {
            if (pct < 25)
                return Color.FromArgb(225, 75, 55);
            if (pct < 50)
                return Color.FromArgb(240, 185, 45);
            return Color.FromArgb(60, 190, 105);
        }

        private static Color DigitColor(int pct)
        {
            if (pct < 10)
                return Color.FromArgb(255, 105, 90);
            if (pct < 25)
                return Color.FromArgb(255, 130, 110);
            if (pct < 50)
                return Color.FromArgb(252, 215, 80);
            return Color.FromArgb(90, 230, 140);
        }

        private void BuildBatteryIcons()
        {
            try
            {
                iconBase16 = LoadEmbeddedIcon(16);

                Color border = Color.FromArgb(235, 235, 235);
                Color gray = Color.FromArgb(160, 160, 160);

                iconByPercent =
                    new System.Collections.Generic.Dictionary<int, Icon>();
                iconNa = MakeBatteryIcon(0.5f, gray, gray, "?",
                    Color.FromArgb(240, 240, 240));
            }
            catch
            {
                iconBase16 = null;
                iconByPercent = null;
                iconNa = null;
            }
        }

        // Draws a 16x16 battery glyph: outlined cell with a terminal nub,
        // interior filled up to `frac`. Result is a real Icon suitable for
        // NotifyIcon.Icon so the level is visible at a glance in the tray.
        private Icon MakeBatteryIcon(float frac, Color fill, Color border,
                string digits, Color digitColor)
        {
            Bitmap bmp = new Bitmap(16, 16);
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.Clear(Color.Transparent);
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.None;

                // charge bar along the bottom edge of the 16 px tile
                if (frac > 0f)
                {
                    int w = (int)(16 * frac);
                    if (w > 16)
                        w = 16;
                    if (w < 1)
                        w = 1;
                    using (SolidBrush b = new SolidBrush(fill))
                    {
                        g.FillRectangle(b, 0, 12, w, 3);
                    }
                }

                if (digits != null && digits.Length > 0)
                {
                    // the number is the icon body: as large as fits, GDI
                    // rendered (crisp at 16 px), centered in the upper area
                    float size = digits.Length >= 3 ? 10f : 12f;
                    Font f = new Font("Arial", size, FontStyle.Bold,
                        GraphicsUnit.Pixel);
                    Size sz = TextRenderer.MeasureText(g, digits, f,
                        new Size(16, 12),
                        TextFormatFlags.NoPadding);
                    while ((sz.Width > 15 || sz.Height > 11) && size > 6f)
                    {
                        f.Dispose();
                        size -= 1f;
                        f = new Font("Arial", size, FontStyle.Bold,
                            GraphicsUnit.Pixel);
                        sz = TextRenderer.MeasureText(g, digits, f,
                            new Size(16, 12),
                            TextFormatFlags.NoPadding);
                    }
                    try
                    {
                        TextRenderer.DrawText(g, digits, f,
                            new Rectangle(0, 0, 16, 11), digitColor,
                            TextFormatFlags.HorizontalCenter |
                            TextFormatFlags.VerticalCenter |
                            TextFormatFlags.NoPadding);
                    }
                    finally
                    {
                        f.Dispose();
                    }
                }
            }

            // FromHandle does not take ownership of the handle, and we must
            // not destroy it afterwards (the icon must outlive this method);
            // the icons are built once per process, so the few native handles
            // live for the life of the app - acceptable.
            IntPtr h = bmp.GetHicon();
            bmp.Dispose();
            return Icon.FromHandle(h);
        }

        private const string AutoStartTaskName = "MagicTrackpad";

        private void WriteAutoStart()
        {
            try
            {
                // Drop the legacy HKCU Run entry. It launched the app unelevated,
                // so Windows asked for elevation at every logon - and a prompt
                // nobody clicks times out (auto-deny), which left no tray icon at
                // all on an unattended machine.
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(
                    @"Software\Microsoft\Windows\CurrentVersion\Run", true))
                {
                    if (key != null && key.GetValue("Magic Trackpad") != null)
                        key.DeleteValue("Magic Trackpad", false);
                }

                if (SettingAutoStart)
                {
                    string command = "\"" + Application.ExecutablePath + "\"";
                    if (SettingStartMin)
                        command += " -minimized";

                    // RunLevel Highest starts the app elevated straight away, so
                    // there is no UAC consent prompt at logon.
                    RunSchtasks("/Create /TN \"" + AutoStartTaskName + "\" /TR \"" +
                        command.Replace("\"", "\\\"") +
                        "\" /SC ONLOGON /RL HIGHEST /F");
                }
                else
                {
                    RunSchtasks("/Delete /TN \"" + AutoStartTaskName + "\" /F");
                }
            }
            catch
            {
            }
        }

        private static void RunSchtasks(string arguments)
        {
            try
            {
                System.Diagnostics.ProcessStartInfo psi = new System.Diagnostics.ProcessStartInfo();
                psi.FileName = "schtasks.exe";
                psi.Arguments = arguments;
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                using (System.Diagnostics.Process p = System.Diagnostics.Process.Start(psi))
                {
                    if (p != null)
                        p.WaitForExit(15000);
                }
            }
            catch
            {
            }
        }

        // One-time migration: an install created before the logon task existed still
        // carries the HKCU Run entry that raised the UAC prompt at every logon.
        private void MigrateAutoStart()
        {
            try
            {
                if (!SettingAutoStart)
                    return;

                bool legacyRun = false;
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(
                    @"Software\Microsoft\Windows\CurrentVersion\Run"))
                {
                    legacyRun = (key != null && key.GetValue("Magic Trackpad") != null);
                }

                if (legacyRun)
                    WriteAutoStart();
            }
            catch
            {
            }
        }

        private Icon LoadEmbeddedIcon(int size)
        {
            Assembly asm = typeof(Main).Assembly;
            using (Stream stream = asm.GetManifestResourceStream("AmtPtpControlPanel.Icon1.ico"))
            {
                if (stream == null)
                    return new Icon(SystemIcons.Application, size, size);
                return new Icon(stream, size, size);
            }
        }

        //=================
        // Main-window option tooltips
        //=================

        private void WireControlTooltips()
        {
            try
            {
                tipOptions = new System.Windows.Forms.ToolTip();
                tipOptions.InitialDelay = 300;

                tipOptions.SetToolTip(ctlMacOSClickOptions,
                    "macOS-style progressive click: how hard you press decides whether a " +
                    "click registers (tap = light press, click = firmer press). Adjust the " +
                    "strength on the slider below.");
                tipOptions.SetToolTip(ctlSilentClicking,
                    "Same progressive behavior, but without the simulated mechanical " +
                    "click - no audible/mechanical click feedback at all.");
                tipOptions.SetToolTip(ctlFeedback,
                    "How much extra press beyond the normal click bottom-out is needed " +
                    "before a 'real' click registers: Light = easiest, Firm = hardest. " +
                    "Applies only when macOS click options are selected.");
                tipOptions.SetToolTip(ctlDisableFeedback,
                    "No force-feedback at all: a click registers the moment the physical " +
                    "button bottom-out is reached.");
                tipOptions.SetToolTip(ctlMaximumFeedback,
                    "Softest click detection: even the lightest touch registers a full " +
                    "click.");
                tipOptions.SetToolTip(ctlStopDoNothing,
                    "No early stopping of scroll/swipe gestures - they continue until " +
                    "you lift your finger.");
                tipOptions.SetToolTip(ctlStopPressure,
                    "Scrolling/stopping the gesture when a pressed finger pushes " +
                    "harder than the threshold - press down firmly to stop momentum.");
                tipOptions.SetToolTip(ctlStopPressureValue,
                    "Pressure threshold in raw force units: higher values need a " +
                    "firmer press to stop the gesture. -1 disables this mode.");
                tipOptions.SetToolTip(ctlStopSize,
                    "Stops the gesture when the contact area grows beyond the threshold " +
                    "(for example when the finger flattens out or a second finger joins).");
                tipOptions.SetToolTip(ctlStopSizeValue,
                    "Contact-area threshold in square millimeters. Larger values let " +
                    "the gesture survive a bigger, flatter contact. -1 disables this mode.");
                tipOptions.SetToolTip(ctlFocusHack,
                    "Debug field forwarded to the driver. Leave it untouched unless you " +
                    "are testing the focus-handling patch.");
                tipOptions.SetToolTip(ctlPalmRejection,
                    "Filters out large pad contacts (resting palm) so the cursor does " +
                    "not jump while your palm lies on the trackpad.");
                tipOptions.SetToolTip(ctlIgnoreButtonFinger,
                    "While a click is being pressed, the pressing finger is ignored for " +
                    "cursor movement - prevents the cursor sliding under your fingertip.");
                tipOptions.SetToolTip(ctlIgnoreNearFingers,
                    "Fingers lying close to the pressing finger are ignored as well, " +
                    "so the cursor does not wander during a click-and-hold.");
                tipOptions.SetToolTip(ctlBatteryGroupBox,
                    "Charge of the trackpad's internal battery. The driver exposes it " +
                    "only in Bluetooth mode; with a USB cable the level cannot be read.");
                tipOptions.SetToolTip(ctlBatteryUpdate,
                    "Reads the current battery percentage from the driver right now. " +
                    "Refuses silently in USB mode - connect via Bluetooth to use it.");
                tipOptions.SetToolTip(ctlShowBatteryInTray,
                    "When on, the tray icon changes with the charge level (green " +
                    "full/high, amber medium, red low) and the percentage shows in " +
                    "the tray menu and the icon's hover text, refreshed every 5 " +
                    "seconds. Bluetooth mode only - in USB mode the driver exposes " +
                    "no level and the icon shows a gray question mark. Same switch " +
                    "is in the right-click menu of the tray icon.");
                tipOptions.SetToolTip(ctlStartupGroupBox,
                    "Controls what happens at login: whether the app starts on its " +
                    "own and whether it should appear only as a tray icon.");
                tipOptions.SetToolTip(ctlStartAuto,
                    "Registers an elevated logon task for the current user (schtasks " +
                    "/SC ONLOGON /RL HIGHEST). Windows starts the app already elevated, " +
                    "so there is no UAC prompt at login and an unattended machine still " +
                    "gets its tray icon. Same option is in the tray icon's right-click menu.");
                tipOptions.SetToolTip(ctlStartHidden,
                    "Only relevant together with 'Start automatically at login': " +
                    "at login the app appears as a tray icon only - no window pops " +
                    "up. Double-click the tray icon (or use 'Open') to bring up the " +
                    "settings window. When you start the app by hand this has no " +
                    "effect. Same option is in the tray icon's right-click menu.");
                tipOptions.SetToolTip(ctlApply,
                    "Saves all options to the driver configuration and applies them " +
                    "immediately - the running driver picks them up without a reboot.");
                tipOptions.SetToolTip(ctlTouchpadSettings,
                    "Opens the standard Windows 'Touchpad' settings page (pointer " +
                    "speed, tap handling).");
            }
            catch
            {
            }
        }
    }

    // ==================================================================
    // Force click: a firm press on the trackpad can act as a second click.
    // The (optional) force-click driver build watches the contact pressure and
    // signals a named event; this panel performs the configured action with
    // SendInput. Everything is event driven - nothing polls.
    // ==================================================================
    public partial class Main
    {
        private const string ForceClickEventName = "Global\\MagicTrackpad.ForceClick";
        private const string DriverParamsPath =
            @"SOFTWARE\Microsoft\Windows NT\CurrentVersion\WUDF\Services\AmtPtpDeviceUsbUm\Parameters";

        private CheckBox ctlForceClick;
        private Label ctlForceStatus;
        private Label ctlForceStatusNote;
        private ComboBox ctlForceAction;
        private TrackBar ctlForcePressure;
        private Label ctlForcePressureValue;
        private System.Windows.Forms.Timer forceClickApplyTimer;
        private System.Threading.EventWaitHandle forceClickEvent;
        private int forceClickAction = 0;
        private int forceClickPressure = 0;

        // Rotation group of the settings window (twin of the tray submenu).
        private RadioButton[] ctlRotationRadios;
        private Label ctlRotationStatus;
        private Label ctlRotationStatusNote;
        // bottom edge of the last runtime-built group, so the next one stacks
        private int uiStackBottom = 0;

        private static readonly string[] ForceClickActions = new string[]
        {
            "Right mouse button (default)",
            "Middle mouse button",
            "Double left click",
            "Mouse back (X1)",
            "Mouse forward (X2)",
            "Ctrl + Left click",
            "Enter / Return",
            "Do nothing"
        };

        // Layout helpers for the runtime-built groups.
        //
        // Every control is parented BEFORE its text is set, so AutoSize measures
        // with the group's real (font-scaled) font, and every position comes
        // from the previous sibling's actual geometry instead of an estimate.
        // Estimates are what clipped the "no UAC prompt" line and painted over
        // the first rotation radio button.
        private static Label AddLabel(Control parent, string text)
        {
            Label l = new Label();
            l.AutoSize = true;
            parent.Controls.Add(l);
            l.Text = text;
            return l;
        }

        // AutoSize + a maximum width: the label wraps and grows downwards, so a
        // long status text can never be cut off by a fixed height.
        private static Label AddWrappedLabel(Control parent, string text, int maxWidth)
        {
            Label l = new Label();
            l.AutoSize = true;
            l.MaximumSize = new System.Drawing.Size(maxWidth, 0);
            parent.Controls.Add(l);
            l.Text = text;
            return l;
        }

        private static CheckBox AddCheckBox(Control parent, string text)
        {
            CheckBox c = new CheckBox();
            c.AutoSize = true;
            parent.Controls.Add(c);
            c.Text = text;
            return c;
        }

        private void BuildForceClickUi()
        {
            try
            {
                // Borrow the Startup group's real (runtime-scaled) geometry:
                // the designer controls are DPI/font scaled, so hard-coded
                // pixel sizes would not match this form at all.
                int gw = (ctlStartupGroupBox != null) ? ctlStartupGroupBox.Width : 600;
                int gx = (ctlStartupGroupBox != null) ? ctlStartupGroupBox.Left : 13;
                int gy = (ctlStartupGroupBox != null)
                        ? ctlStartupGroupBox.Bottom + 8 : 800;

                GroupBox g = new GroupBox();
                g.Text = "Force click  (needs the force-click driver build)";
                g.Size = new System.Drawing.Size(gw, 200);   // fitted to the content below
                g.Location = new System.Drawing.Point(gx, gy);
                g.TabIndex = 18;

                int inner = gw - 32;
                const int left = 16;
                int rowY = 22;

                ctlForceClick = AddCheckBox(g, "Simulate force click (press harder for a second click)");
                ctlForceClick.Location = new System.Drawing.Point(left, rowY);
                rowY = ctlForceClick.Bottom + 10;

                Label lblAction = AddLabel(g, "Action on force press:");
                lblAction.Location = new System.Drawing.Point(left, rowY + 3);

                ctlForceAction = new ComboBox();
                ctlForceAction.DropDownStyle = ComboBoxStyle.DropDownList;
                g.Controls.Add(ctlForceAction);          // parent first: real font
                ctlForceAction.Items.AddRange(ForceClickActions);
                int actionW = 120;
                foreach (string s in ForceClickActions)
                    actionW = Math.Max(actionW, TextRenderer.MeasureText(s, ctlForceAction.Font).Width);
                ctlForceAction.Size = new System.Drawing.Size(actionW + 34, ctlForceAction.PreferredHeight);
                ctlForceAction.Location = new System.Drawing.Point(lblAction.Right + 10, rowY);
                rowY = Math.Max(lblAction.Bottom, ctlForceAction.Bottom) + 12;

                // Pressure threshold is a slider with the raw value next to it:
                // the value only matters relative to a firm press, and a slider
                // shows where the current setting sits in the 1-255 range.
                Label lblPressure = AddLabel(g, "Pressure threshold:");
                lblPressure.Location = new System.Drawing.Point(left, rowY + 8);

                ctlForcePressure = new TrackBar();
                ctlForcePressure.AutoSize = false;
                ctlForcePressure.Minimum = 1;
                ctlForcePressure.Maximum = 255;
                ctlForcePressure.TickFrequency = 32;
                ctlForcePressure.SmallChange = 5;
                ctlForcePressure.LargeChange = 25;
                ctlForcePressure.Value = 200;
                g.Controls.Add(ctlForcePressure);         // parent first: real font
                int sliderW = inner - lblPressure.Width - 110;
                if (sliderW < 150) sliderW = 150;
                if (sliderW > 320) sliderW = 320;
                ctlForcePressure.Size = new System.Drawing.Size(sliderW, 32);
                ctlForcePressure.Location = new System.Drawing.Point(lblPressure.Right + 10, rowY + 1);

                ctlForcePressureValue = new Label();
                ctlForcePressureValue.AutoSize = true;
                g.Controls.Add(ctlForcePressureValue);
                ctlForcePressureValue.Text = "200";
                ctlForcePressureValue.Location =
                    new System.Drawing.Point(ctlForcePressure.Right + 10, rowY + 8);
                rowY = Math.Max(ctlForcePressure.Bottom, ctlForcePressureValue.Bottom) + 12;

                // Which firmware/signing state is this machine in? It decides
                // whether the self-signed force-click driver can load at all.
                // Two labels: the state line can be highlighted, the note cannot
                // be mixed into it (a Label carries one colour for the whole text).
                // The text is set here, not after the layout, because the note
                // and the group height are derived from this label's height.
                ctlForceStatus = AddWrappedLabel(g, SigningStateText(), inner);
                StyleSigningLabel(ctlForceStatus);
                ctlForceStatus.Location = new System.Drawing.Point(left, rowY);
                ctlForceStatusNote = AddWrappedLabel(g, ForceClickNoteText(), inner);
                ctlForceStatusNote.Location = new System.Drawing.Point(left, ctlForceStatus.Bottom + 2);

                this.Controls.Add(g);

                // fit the group to whatever the (font-scaled) content needs
                g.Height = ctlForceStatusNote.Bottom + 12;
                uiStackBottom = g.Bottom;

                // make room for the group
                int needed = g.Bottom + 14;
                if (this.ClientSize.Height < needed)
                    this.ClientSize = new System.Drawing.Size(this.ClientSize.Width, needed);

                // load what the driver currently has
                forceClickPressure = ReadDriverInt("ForceClickPressure", 0);
                forceClickAction = ReadDriverInt("ForceClickAction", 0);
                if (forceClickAction < 0 || forceClickAction >= ForceClickActions.Length)
                    forceClickAction = 0;
                ctlForceAction.SelectedIndex = forceClickAction;

                int initialPressure = (forceClickPressure > 0) ? forceClickPressure : 200;
                if (initialPressure < ctlForcePressure.Minimum) initialPressure = ctlForcePressure.Minimum;
                if (initialPressure > ctlForcePressure.Maximum) initialPressure = ctlForcePressure.Maximum;
                ctlForcePressure.Value = initialPressure;
                ctlForcePressureValue.Text = initialPressure.ToString();
                ctlForceClick.Checked = forceClickPressure > 0;

                RefreshForceClickStatus();

                // Dragging a slider fires ValueChanged for every step; writing the
                // registry and asking the driver to re-read on each of them is
                // pointless, so the write happens once the user stops moving.
                forceClickApplyTimer = new System.Windows.Forms.Timer();
                forceClickApplyTimer.Interval = 250;
                forceClickApplyTimer.Tick += (s, e) =>
                {
                    forceClickApplyTimer.Stop();
                    ApplyForceClickSettings();
                };

                ctlForceClick.CheckedChanged += (s, e) =>
                {
                    ApplyForceClickSettings();
                };
                ctlForceAction.SelectedIndexChanged += (s, e) =>
                {
                    ApplyForceClickSettings();
                };
                ctlForcePressure.ValueChanged += (s, e) =>
                {
                    if (ctlForcePressureValue != null && !ctlForcePressureValue.IsDisposed)
                        ctlForcePressureValue.Text = ctlForcePressure.Value.ToString();
                    forceClickApplyTimer.Stop();
                    forceClickApplyTimer.Start();
                };

                if (tipOptions != null)
                {
                    tipOptions.SetToolTip(g,
                        "Force click uses the pressure sensor of the trackpad: pressing noticeably " +
                        "harder than a normal touch performs the action selected here. It needs the " +
                        "force-click driver build (the Microsoft-signed driver has no pressure " +
                        "interface and simply ignores these settings).");
                    tipOptions.SetToolTip(ctlForceClick,
                        "Off: a firm press does nothing special. On: the driver reports the force " +
                        "press and this panel performs the action below. The pressure threshold " +
                        "decides how hard you have to press - start at the default and raise it if " +
                        "normal clicks trigger it, lower it if you have to press too hard.");
                    tipOptions.SetToolTip(ctlForceAction,
                        "What a force press does: right mouse button (default, same as a two-finger " +
                        "click), middle mouse button, a double left click, browser back / forward, " +
                        "Ctrl + left click or Enter. 'Do nothing' keeps the driver setting but " +
                        "performs no action.");
                    tipOptions.SetToolTip(ctlForcePressure,
                        "Raw pressure value (1-255) at which the action fires; the number next to " +
                        "the slider is the current value. Around 120-180 is a firm press on most " +
                        "units. Lower = easier to trigger, higher = needs a harder press.");
                }

                StartForceClickListener();
            }
            catch (Exception ex)
            {
                try
                {
                    string dir = Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                        "MagicTrackpad");
                    Directory.CreateDirectory(dir);
                    File.AppendAllText(Path.Combine(dir, "forceclick-ui.log"),
                        DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + ex + "\r\n\r\n");
                }
                catch
                {
                }
            }
        }

        [DllImport("kernel32.dll")]
        private static extern bool GetFirmwareType(out uint firmwareType);

        private void RefreshForceClickStatus()
        {
            try
            {
                if (ctlForceStatus != null && !ctlForceStatus.IsDisposed)
                {
                    ctlForceStatus.Text = SigningStateText();
                    StyleSigningLabel(ctlForceStatus);
                }
            }
            catch
            {
            }
        }

        private void RefreshRotationStatus()
        {
            try
            {
                if (ctlRotationStatus != null && !ctlRotationStatus.IsDisposed)
                {
                    ctlRotationStatus.Text = SigningStateText();
                    StyleSigningLabel(ctlRotationStatus);
                }
            }
            catch
            {
            }
        }

        // The one line that decides whether ANY self-signed driver can load on
        // this machine. A configuration that blocks them is drawn red and bold.
        private static string SigningStateText()
        {
            return "Secure Boot: " + SecureBootState() + "     test signing: " + TestSigningState() +
                (SigningBlocked() ? "     -> this blocks the self-signed driver" : "");
        }

        // Self-signed drivers load with Secure Boot off (our certificate is
        // trusted then) or with test signing on. Secure Boot on blocks them.
        private static bool SigningBlocked()
        {
            return SecureBootState() == "ON";
        }

        private static void StyleSigningLabel(Label l)
        {
            bool blocked = SigningBlocked();
            bool bold = (l.Font.Style & FontStyle.Bold) != 0;

            if (blocked)
            {
                l.ForeColor = Color.Red;
                if (!bold)
                    l.Font = new Font(l.Font, FontStyle.Bold);
            }
            else
            {
                l.ForeColor = SystemColors.ControlText;
                if (bold)
                    l.Font = new Font(l.Font, FontStyle.Regular);
            }
        }

        private static string ForceClickNoteText()
        {
            return "The force-click driver is self-signed: it loads with Secure Boot OFF " +
                "(our certificate is trusted in that case) or with test signing ON. With Secure " +
                "Boot on, use the Microsoft-signed driver - force click stays unavailable.";
        }

        private static string RotationNoteText()
        {
            return "Written to the driver's Rotation parameter; the trackpad restarts once " +
                "because the HID report descriptor is re-read only on device start. Needs the " +
                "self-signed rotation driver - the Microsoft-signed driver ignores it, and " +
                "Bluetooth has no rotation yet.";
        }

        private static string SecureBootState()
        {
            try
            {
                uint fw;
                bool uefi = GetFirmwareType(out fw) && fw == 2;   // 2 = UEFI
                if (!uefi)
                    return "not applicable (legacy BIOS)";

                object v = null;
                using (RegistryKey k = Registry.LocalMachine.OpenSubKey(
                        @"SYSTEM\CurrentControlSet\Control\SecureBoot\State"))
                {
                    if (k != null)
                        v = k.GetValue("UEFISecureBootEnabled");
                }
                return (v is int) ? (((int)v) != 0 ? "ON" : "OFF") : "unknown";
            }
            catch
            {
                return "unknown";
            }
        }

        private static string TestSigningState()
        {
            try
            {
                using (RegistryKey k = Registry.LocalMachine.OpenSubKey(
                        @"SYSTEM\CurrentControlSet\Control"))
                {
                    if (k != null)
                    {
                        object v = k.GetValue("SystemStartOptions");
                        if (v is string &&
                            ((string)v).IndexOf("TESTSIGNING", StringComparison.OrdinalIgnoreCase) >= 0)
                            return "ON";
                    }
                }
            }
            catch
            {
            }
            return "off";
        }

        private static int ReadDriverInt(string name, int def)
        {
            try
            {
                using (RegistryKey k = Registry.LocalMachine.OpenSubKey(DriverParamsPath))
                {
                    if (k != null)
                    {
                        object v = k.GetValue(name);
                        if (v is int)
                            return (int)v;
                    }
                }
            }
            catch
            {
            }
            return def;
        }

        private void WriteDriverInt(string name, int value)
        {
            try
            {
                using (RegistryKey k = Registry.LocalMachine.CreateSubKey(DriverParamsPath))
                {
                    if (k != null)
                        k.SetValue(name, value, RegistryValueKind.DWord);
                }
            }
            catch
            {
            }
        }

        private void ApplyForceClickSettings()
        {
            try
            {
                int threshold = 0;
                if (ctlForceClick != null && ctlForceClick.Checked)
                {
                    // the slider can only produce 1-255, but the registry may have
                    // been edited by hand - clamp anyway
                    threshold = (ctlForcePressure != null) ? ctlForcePressure.Value : 200;
                    if (threshold < 1) threshold = 1;
                    if (threshold > 255) threshold = 255;
                }

                int action = 0;
                if (ctlForceAction != null && ctlForceAction.SelectedIndex >= 0)
                    action = ctlForceAction.SelectedIndex;

                int previousPressure = forceClickPressure;
                forceClickPressure = threshold;
                forceClickAction = action;

                // only touch the registry when something really changed
                if (previousPressure != threshold)
                    WriteDriverInt("ForceClickPressure", threshold);
                WriteDriverInt("ForceClickAction", action);

                // the driver picks the threshold up without a reload - it reads it
                // once per device start, so ask it to re-read the settings
                if (previousPressure != threshold)
                    NudgeDriverReload();
            }
            catch
            {
            }
        }

        private void NudgeDriverReload()
        {
            try
            {
                uint dummy;
                BtDevice.SendIoctl(BtDevice.IOCTL_RELOAD_SETTINGS, out dummy, false);
            }
            catch
            {
            }
        }

        //=================
        // Trackpad rotation (driver "Rotation" DWORD: 0 / 90 / 180 / 270)
        //=================

        private void BuildRotationMenu()
        {
            rotationItems = new System.Collections.Generic.Dictionary<int, ToolStripMenuItem>();
            int[] degrees = new int[] { 0, 90, 180, 270 };
            string[] labels = new string[] { "0 degrees (default)", "90 degrees", "180 degrees", "-90 degrees" };

            for (int i = 0; i < degrees.Length; i++)
            {
                int value = degrees[i];
                ToolStripMenuItem item = new ToolStripMenuItem(labels[i]);
                item.Click += (s, e) => ApplyRotation(value);
                rotationItems[value] = item;
                miRotation.DropDownItems.Add(item);
            }

            RefreshRotationChecks();
        }

        private void ApplyRotation(int degrees)
        {
            try
            {
                WriteDriverInt("Rotation", degrees);

                // 90/270 also swap the X/Y axes of the HID report descriptor, and
                // the host only re-reads that when the device restarts - so a
                // restart is part of every rotation change.
                UsbDevice.RestartDevices();
                NudgeDriverReload();
            }
            catch
            {
            }

            RefreshRotationChecks();
        }

        // Settings-window twin of the tray submenu: without it the rotation
        // option was invisible to anyone who never opened the tray menu.
        private void BuildRotationUi()
        {
            try
            {
                int gw = (ctlStartupGroupBox != null) ? ctlStartupGroupBox.Width : 600;
                int gx = (ctlStartupGroupBox != null) ? ctlStartupGroupBox.Left : 13;
                int gy = (uiStackBottom > 0)
                        ? uiStackBottom + 8
                        : ((ctlStartupGroupBox != null) ? ctlStartupGroupBox.Bottom + 8 + 156 + 8 : 966);

                GroupBox g = new GroupBox();
                g.Text = "Rotation  (trackpad, needs the self-signed rotation driver build)";
                g.Size = new System.Drawing.Size(gw, 200);   // fitted to the content below
                g.Location = new System.Drawing.Point(gx, gy);
                g.TabIndex = 19;

                int inner = gw - 32;
                const int left = 16;

                int[] degrees = new int[] { 0, 90, 180, 270 };
                string[] labels = new string[] { "0 degrees (default)", "90 degrees", "180 degrees", "-90 degrees" };

                ctlRotationRadios = new RadioButton[degrees.Length];
                // Sequential placement from each radio's actual AutoSize width:
                // no separate "Trackpad:" label (it overlapped the first radio and
                // erased its circle), and wrap to a second row if the row of four
                // ever gets wider than the group.
                int x = left;
                int y = 24;
                int rowH = 0;
                for (int i = 0; i < degrees.Length; i++)
                {
                    RadioButton rb = new RadioButton();
                    rb.AutoSize = true;
                    g.Controls.Add(rb);              // parent first: real font
                    rb.Text = labels[i];

                    if (x > left && (x + rb.Width) > inner)
                    {
                        x = left;
                        y += rowH + 6;
                        rowH = 0;
                    }

                    rb.Location = new System.Drawing.Point(x, y);
                    if (rb.Height > rowH)
                        rowH = rb.Height;
                    x = rb.Right + 20;

                    int value = degrees[i];
                    // Click (not CheckedChanged): RefreshRotationChecks sets
                    // Checked itself and must not write the setting back
                    rb.Click += (s, e) => ApplyRotation(value);
                    ctlRotationRadios[i] = rb;
                }

                int statusY = y + rowH + 12;

                // state line (red + bold when this machine blocks self-signed
                // drivers) and the explanation, as two separate labels
                ctlRotationStatus = AddWrappedLabel(g, SigningStateText(), inner);
                StyleSigningLabel(ctlRotationStatus);
                ctlRotationStatus.Location = new System.Drawing.Point(left, statusY);
                ctlRotationStatusNote = AddWrappedLabel(g, RotationNoteText(), inner);
                ctlRotationStatusNote.Location = new System.Drawing.Point(left, ctlRotationStatus.Bottom + 2);

                this.Controls.Add(g);

                g.Height = ctlRotationStatusNote.Bottom + 12;

                int needed = g.Bottom + 14;
                if (this.ClientSize.Height < needed)
                    this.ClientSize = new System.Drawing.Size(this.ClientSize.Width, needed);

                if (tipOptions != null)
                {
                    tipOptions.SetToolTip(g,
                        "Turns the trackpad input in 90 degree steps (same setting as the tray menu's " +
                        "Rotation submenu). The driver re-reads it when the device restarts, so the " +
                        "trackpad blinks once after a change.");
                    tipOptions.SetToolTip(ctlRotationStatus,
                        "Rotation is implemented in the USB (UMDF) driver, so it needs the " +
                        "self-signed driver built with rotation support; the Microsoft-signed " +
                        "driver ignores the setting. The Bluetooth path has no rotation yet.");
                }

                RefreshRotationChecks();
                RefreshRotationStatus();
            }
            catch (Exception ex)
            {
                try
                {
                    string dir = Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                        "MagicTrackpad");
                    Directory.CreateDirectory(dir);
                    File.AppendAllText(Path.Combine(dir, "rotation-ui.log"),
                        DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + ex + "\r\n\r\n");
                }
                catch
                {
                }
            }
        }

        private void RefreshRotationChecks()
        {
            int current = ReadDriverInt("Rotation", 0);

            if (rotationItems != null)
            {
                foreach (System.Collections.Generic.KeyValuePair<int, ToolStripMenuItem> pair in rotationItems)
                    pair.Value.Checked = (pair.Key == current);
            }

            if (ctlRotationRadios != null)
            {
                int[] degrees = new int[] { 0, 90, 180, 270 };
                for (int i = 0; i < ctlRotationRadios.Length && i < degrees.Length; i++)
                {
                    RadioButton rb = ctlRotationRadios[i];
                    if (rb != null && !rb.IsDisposed)
                        rb.Checked = (degrees[i] == current);
                }
            }
        }

        private void StartForceClickListener()
        {
            try
            {
                // create the event ourselves so it always exists; the driver's
                // CreateEventW then finds (and signals) this very object
                forceClickEvent = new System.Threading.EventWaitHandle(false,
                    System.Threading.EventResetMode.AutoReset, ForceClickEventName);

                System.Threading.Thread t = new System.Threading.Thread(delegate()
                {
                    while (true)
                    {
                        try
                        {
                            if (!forceClickEvent.WaitOne(1000))
                                continue;
                            int action = forceClickAction;
                            if (forceClickPressure <= 0 || action < 0 || action > 6)
                                continue;

                            // "Double left click" and "Ctrl + Left click" press
                            // button 1 themselves; while the user is holding the
                            // trackpad button (dragging) that would cancel the
                            // drag, so they are skipped in that moment.
                            bool touchesLeftButton = (action == 2 || action == 5);
                            if (touchesLeftButton && ForceClickAction.LeftButtonDown())
                                continue;

                            ForceClickAction.Perform(action);
                        }
                        catch
                        {
                        }
                    }
                });
                t.IsBackground = true;
                t.Name = "mt-forceclick";
                t.Start();
            }
            catch
            {
            }
        }
    }

    // Performs the configured "second click" with SendInput.
    public static class ForceClickAction
    {
        private const uint INPUT_MOUSE = 0;
        private const uint INPUT_KEYBOARD = 1;

        private const uint LEFTDOWN = 0x0002, LEFTUP = 0x0004;
        private const uint RIGHTDOWN = 0x0008, RIGHTUP = 0x0010;
        private const uint MIDDLEDOWN = 0x0020, MIDDLEUP = 0x0040;
        private const uint XDOWN = 0x0080, XUP = 0x0100;
        private const uint KEYUP = 0x0002;
        private const ushort VK_RETURN = 0x0D, VK_CONTROL = 0x11;

        [StructLayout(LayoutKind.Sequential)]
        private struct MOUSEINPUT
        {
            public int dx, dy;
            public uint mouseData, dwFlags, time;
            public IntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct KEYBDINPUT
        {
            public ushort wVk, wScan;
            public uint dwFlags, time;
            public IntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Explicit)]
        private struct InputUnion
        {
            [FieldOffset(0)] public MOUSEINPUT mi;
            [FieldOffset(0)] public KEYBDINPUT ki;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct INPUT
        {
            public uint type;
            public InputUnion u;
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(int vKey);

        // VK_LBUTTON: true while the physical button is held
        public static bool LeftButtonDown()
        {
            try
            {
                return (GetAsyncKeyState(0x01) & 0x8000) != 0;
            }
            catch
            {
                return false;
            }
        }

        private static INPUT Mouse(uint flags, uint data)
        {
            INPUT i = new INPUT();
            i.type = INPUT_MOUSE;
            i.u.mi.dwFlags = flags;
            i.u.mi.mouseData = data;
            return i;
        }

        private static INPUT Key(ushort vk, bool up)
        {
            INPUT i = new INPUT();
            i.type = INPUT_KEYBOARD;
            i.u.ki.wVk = vk;
            i.u.ki.dwFlags = up ? KEYUP : 0;
            return i;
        }

        private static void Send(INPUT[] inputs)
        {
            try
            {
                SendInput((uint)inputs.Length, inputs,
                    Marshal.SizeOf(typeof(INPUT)));
            }
            catch
            {
            }
        }

        // 0 right, 1 middle, 2 double left, 3 back, 4 forward, 5 ctrl+left, 6 enter
        public static void Perform(int action)
        {
            switch (action)
            {
                case 0:
                    Send(new INPUT[] { Mouse(RIGHTDOWN, 0), Mouse(RIGHTUP, 0) });
                    break;
                case 1:
                    Send(new INPUT[] { Mouse(MIDDLEDOWN, 0), Mouse(MIDDLEUP, 0) });
                    break;
                case 2:
                    // two separate pairs - a single burst is often coalesced
                    Send(new INPUT[] { Mouse(LEFTDOWN, 0), Mouse(LEFTUP, 0) });
                    System.Threading.Thread.Sleep(40);
                    Send(new INPUT[] { Mouse(LEFTDOWN, 0), Mouse(LEFTUP, 0) });
                    break;
                case 3:
                    Send(new INPUT[] { Mouse(XDOWN, 1), Mouse(XUP, 1) });   // XBUTTON1
                    break;
                case 4:
                    Send(new INPUT[] { Mouse(XDOWN, 2), Mouse(XUP, 2) });   // XBUTTON2
                    break;
                case 5:
                    Send(new INPUT[] {
                        Key(VK_CONTROL, false), Mouse(LEFTDOWN, 0),
                        Mouse(LEFTUP, 0), Key(VK_CONTROL, true) });
                    break;
                case 6:
                    Send(new INPUT[] { Key(VK_RETURN, false), Key(VK_RETURN, true) });
                    break;
            }
        }
    }

    // Overlapped-I/O battery reader: never blocks the UI thread.
    public class TrayBattery
    {
        private const uint FILE_DEVICE_UNKNOWN = 0x00000022;
        private const uint METHOD_BUFFERED = 0;
        private const uint FILE_ANY_ACCESS = 0;
        private const uint IOCTL_GET_BATTERY = (FILE_DEVICE_UNKNOWN << 16) | (FILE_ANY_ACCESS << 14) | (0x801u << 2) | METHOD_BUFFERED;

        private const uint GENERIC_READ = 0x80000000;
        private const uint GENERIC_WRITE = 0x40000000;
        private const uint OPEN_EXISTING = 3;
        private const uint FILE_SHARE_READ = 1;
        private const uint FILE_SHARE_WRITE = 2;
        // NOTE: the return type must be a CONCRETE SafeHandle type. Declaring
        // the abstract SafeHandle base class here makes every call fail with
        // MarshalDirectiveException ("Returned SafeHandles cannot be abstract")
        // at runtime - which silently killed every battery read until
        // 2026-09-20. Parameters may stay abstract, returns may not.
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        private static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFile(
            string lpFileName,
            uint dwDesiredAccess,
            uint dwShareMode,
            IntPtr lpSecurityAttributes,
            uint dwCreationDisposition,
            uint dwFlagsAndAttributes,
            IntPtr hTemplateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DeviceIoControl(
            Microsoft.Win32.SafeHandles.SafeFileHandle hDevice,
            uint dwIoControlCode,
            IntPtr lpInBuffer,
            uint nInBufferSize,
            IntPtr lpOutBuffer,
            uint nOutBufferSize,
            out uint lpBytesReturned,
            IntPtr lpOverlapped);

        // Synchronous read, exactly like the control panel's own
        // "Update Battery" button: the UM driver rejects overlapped I/O
        // (ERROR_INVALID_PARAMETER), which is why the earlier overlapped
        // implementation could never return a value.
        public static bool TryGetBattery(out int percent)
        {
            percent = -1;
            Microsoft.Win32.SafeHandles.SafeFileHandle hDevice = null;
            IntPtr pOutBuffer = IntPtr.Zero;

            try
            {
                hDevice = CreateFile(
                    @"\\.\AmtPtpControlDeviceUm",
                    GENERIC_READ | GENERIC_WRITE,
                    FILE_SHARE_READ | FILE_SHARE_WRITE,
                    IntPtr.Zero,
                    OPEN_EXISTING,
                    0,
                    IntPtr.Zero);

                if (hDevice == null || hDevice.IsInvalid)
                    return false;

                pOutBuffer = Marshal.AllocHGlobal(4);
                Marshal.WriteInt32(pOutBuffer, 0, -1);

                uint bytes;
                if (!DeviceIoControl(hDevice, IOCTL_GET_BATTERY,
                        IntPtr.Zero, 0, pOutBuffer, 4, out bytes, IntPtr.Zero))
                    return false;

                int v = Marshal.ReadInt32(pOutBuffer);
                if (v >= 0 && v <= 100)
                {
                    percent = v;
                    return true;
                }
                return false;
            }
            catch
            {
                return false;
            }
            finally
            {
                if (pOutBuffer != IntPtr.Zero)
                    Marshal.FreeHGlobal(pOutBuffer);
                if (hDevice != null)
                    hDevice.Dispose();
            }
        }
    }

}
