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
    //  - "Start with Windows" toggle (HKCU Run key "Magic Trackpad")
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
                    "Adds 'Magic Trackpad' to the current user's startup. The app " +
                    "requires admin rights, so at each login a UAC prompt appears - " +
                    "accept it to keep the tray icon, or the app waits (with a dialog) " +
                    "until you retry. Settings are per-user, the elevated copy uses " +
                    "your usual user profile.";
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
                trayMenu.Opening += (s, e) => RefreshTray();
                trayMenu.Items.Add(miBatteryItem);
                trayMenu.Items.Add(new ToolStripSeparator());
                trayMenu.Items.Add(miShowBattery);
                trayMenu.Items.Add(miAutoStart);
                trayMenu.Items.Add(miStartMin);
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

        private void WriteAutoStart()
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true))
                {
                    if (key == null)
                        return;

                    if (SettingAutoStart)
                    {
                        string path = "\"" + Application.ExecutablePath + "\"";
                        if (SettingStartMin)
                            path += " -minimized";
                        key.SetValue("Magic Trackpad", path, RegistryValueKind.String);
                    }
                    else
                    {
                        if (key.GetValue("Magic Trackpad") != null)
                            key.DeleteValue("Magic Trackpad", false);
                    }
                }
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
                    "Adds 'Magic Trackpad' to the current user's startup. The app " +
                    "requires admin rights, so at each login a UAC prompt appears - " +
                    "accept it to keep the tray icon, or the app waits (with a dialog) " +
                    "until you retry. Same option is in the tray icon's right-click menu.");
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
        private ComboBox ctlForceAction;
        private TextBox ctlForcePressure;
        private System.Threading.EventWaitHandle forceClickEvent;
        private int forceClickAction = 0;
        private int forceClickPressure = 0;

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
                g.Size = new System.Drawing.Size(gw, 118);
                g.Location = new System.Drawing.Point(gx, gy);
                g.TabIndex = 18;

                int inner = gw - 32;

                ctlForceClick = new CheckBox();
                ctlForceClick.AutoSize = false;
                ctlForceClick.Location = new System.Drawing.Point(16, 20);
                ctlForceClick.Size = new System.Drawing.Size(inner, 22);
                ctlForceClick.Text = "Simulate force click (press harder for a second click)";
                g.Controls.Add(ctlForceClick);

                Label lblAction = new Label();
                lblAction.AutoSize = false;
                lblAction.Location = new System.Drawing.Point(16, 52);
                lblAction.Size = new System.Drawing.Size(140, 20);
                lblAction.Text = "Action on force press:";
                g.Controls.Add(lblAction);

                ctlForceAction = new ComboBox();
                ctlForceAction.DropDownStyle = ComboBoxStyle.DropDownList;
                ctlForceAction.Location = new System.Drawing.Point(158, 49);
                ctlForceAction.Size = new System.Drawing.Size(200, 21);
                ctlForceAction.Items.AddRange(ForceClickActions);
                g.Controls.Add(ctlForceAction);

                Label lblPressure = new Label();
                lblPressure.AutoSize = false;
                lblPressure.Location = new System.Drawing.Point(gw - 330, 52);
                lblPressure.Size = new System.Drawing.Size(190, 20);
                lblPressure.Text = "Pressure threshold (1-255):";
                g.Controls.Add(lblPressure);

                ctlForcePressure = new TextBox();
                ctlForcePressure.Location = new System.Drawing.Point(gw - 132, 49);
                ctlForcePressure.Size = new System.Drawing.Size(54, 21);
                ctlForcePressure.TextAlign = HorizontalAlignment.Center;
                g.Controls.Add(ctlForcePressure);

                // Which firmware/signing state is this machine in? It decides
                // whether the self-signed force-click driver can load at all.
                ctlForceStatus = new Label();
                ctlForceStatus.AutoSize = false;
                ctlForceStatus.Location = new System.Drawing.Point(16, 74);
                ctlForceStatus.Size = new System.Drawing.Size(inner, 36);
                ctlForceStatus.Text = ForceClickStatusText();
                g.Controls.Add(ctlForceStatus);

                this.Controls.Add(g);

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
                ctlForcePressure.Text = (forceClickPressure > 0 ? forceClickPressure : 200).ToString();
                ctlForceClick.Checked = forceClickPressure > 0;

                ctlForceClick.CheckedChanged += (s, e) =>
                {
                    ApplyForceClickSettings();
                };
                ctlForceAction.SelectedIndexChanged += (s, e) =>
                {
                    ApplyForceClickSettings();
                };
                ctlForcePressure.TextChanged += (s, e) =>
                {
                    ApplyForceClickSettings();
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
                        "Raw pressure value (1-255) at which the action fires. Around 120-180 is a " +
                        "firm press on most units. Lower = easier to trigger.");
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
                    ctlForceStatus.Text = ForceClickStatusText();
            }
            catch
            {
            }
        }

        // "Secure Boot: OFF | test signing: OFF" plus the reason it matters.
        private static string ForceClickStatusText()
        {
            string secureBoot;
            try
            {
                uint fw;
                bool uefi = GetFirmwareType(out fw) && fw == 2;   // 2 = UEFI
                if (!uefi)
                {
                    secureBoot = "not applicable (legacy BIOS)";
                }
                else
                {
                    object v = null;
                    using (RegistryKey k = Registry.LocalMachine.OpenSubKey(
                            @"SYSTEM\CurrentControlSet\Control\SecureBoot\State"))
                    {
                        if (k != null)
                            v = k.GetValue("UEFISecureBootEnabled");
                    }
                    secureBoot = (v is int) ? (((int)v) != 0 ? "ON" : "OFF") : "unknown";
                }
            }
            catch
            {
                secureBoot = "unknown";
            }

            string testSigning = "off";
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
                            testSigning = "ON";
                    }
                }
            }
            catch
            {
            }

            bool blocked = (secureBoot == "ON") && (testSigning != "ON");

            return "Secure Boot: " + secureBoot + "     test signing: " + testSigning +
                (blocked ? "     -> cannot load the force-click driver as configured" : "") +
                "\r\nThe force-click driver is self-signed: it loads only with Secure Boot OFF " +
                "(our certificate is trusted in that case) or with test signing ON. With Secure Boot " +
                "on, use the Microsoft-signed driver - force click stays unavailable.";
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
                    int parsed;
                    if (int.TryParse(ctlForcePressure.Text, out parsed))
                    {
                        if (parsed < 1) parsed = 1;
                        if (parsed > 255) parsed = 255;
                        threshold = parsed;
                    }
                    else
                    {
                        threshold = 200;
                    }
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
