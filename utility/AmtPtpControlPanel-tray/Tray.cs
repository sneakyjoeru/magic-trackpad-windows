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
        private bool hiddenOnStartup = false;
        private bool trayExitRequested = false;
        private int trayCloseCount = 0;
        private System.Windows.Forms.ToolTip tipOptions;
        private Icon iconBase16;
        private Icon iconNa;
        // one icon per percentage value actually reported: the tray icon
        // carries the literal number so the level is visible even where
        // Windows 11 hides the text next to tray icons
        private System.Collections.Generic.Dictionary<int, Icon> iconByPercent;

        private void TrayWire(string[] args)
        {
            WireControlTooltips();

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
            this.FormClosing += (s, e) =>
            {
                try
                {
                    if (trayIcon == null || trayExitRequested)
                        return;
                    trayCloseCount += 1;
                    if (trayCloseCount == 1)
                    {
                        // first close: park in the tray instead of quitting
                        WindowState = FormWindowState.Minimized;
                        ShowInTaskbar = false;
                        Visible = false;
                        trayIcon.BalloonTipTitle = "Magic Trackpad";
                        trayIcon.BalloonTipText = "Window hidden - the app now lives in the tray icon (right-click it). Press the window close button a second time or use 'Exit' in the icon menu to really quit.";
                        trayIcon.ShowBalloonTip(5000);
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
                if ((System.DateTime.Now - lastUiRefresh)
                        .TotalMilliseconds > 1000)
                {
                    lastUiRefresh = System.DateTime.Now;
                    RefreshTray();
                }
            };
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
                trayTimer.Interval = 5000;
                trayTimer.Tick += (s, e) => RefreshTray();
                trayTimer.Start();

                RefreshTray();
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
                        // the icon itself changes with the charge level, so the
                        // state is visible even where Windows 11 hides the small
                        // label next to tray icons; Text doubles as the hover
                        // tooltip with the exact number
                        if (PickBatteryIcon(lastBatteryPercent) != null)
                            trayIcon.Icon = PickBatteryIcon(lastBatteryPercent);
                        // the tooltip repeats the exact menu phrasing, so the
                        // full "Show battery percentage in tray" wording is
                        // visible right in the tray on hover
                        trayIcon.Text = "Show battery percentage in tray - "
                                + lastBatteryPercent + " %";
                    }
                    else
                    {
                        miBatteryItem.Text = "Battery: not available";
                        if (iconNa != null)
                            trayIcon.Icon = iconNa;
                        trayIcon.Text = "Show battery percentage in tray - "
                                + "no reading in USB mode";
                    }
                }
                else
                {
                    miBatteryItem.Text = "Battery: off";
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

            Color fill = Color.FromArgb(40, 190, 90);
            Color digit = Color.FromArgb(20, 25, 20);
            if (pct < 10)
            {
                fill = Color.FromArgb(205, 55, 45);
                digit = Color.FromArgb(250, 250, 250);
            }
            else if (pct < 25)
            {
                fill = Color.FromArgb(240, 80, 60);
                digit = Color.FromArgb(250, 250, 250);
            }
            else if (pct < 50)
            {
                fill = Color.FromArgb(245, 195, 40);
            }

            Icon built = MakeBatteryIcon(pct / 100f, fill,
                Color.FromArgb(235, 235, 235), pct.ToString(), digit);
            if (built != null)
                iconByPercent[pct] = built;
            return built;
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

                using (Pen p = new Pen(border))
                {
                    g.DrawRectangle(p, 0, 3, 14, 10);     // cell body outline
                    g.FillRectangle(new SolidBrush(border), 14, 6, 1, 4); // terminal
                }

                if (frac > 0f)
                {
                    int w = (int)(12 * frac);
                    if (w > 12)
                        w = 12;
                    if (w < 1)
                        w = 1;
                    using (SolidBrush b = new SolidBrush(fill))
                    {
                        g.FillRectangle(b, 1, 4, w, 8);   // interior fill
                    }
                }

                if (digits != null && digits.Length > 0)
                {
                    // digits rendered with GDI (crisp at 16 px) and centered
                    // in the interior; for the "no reading" glyph digits is "?"
                    using (Font f = new Font("Arial",
                        digits.Length > 1 ? 6.5f : 8.5f,
                        FontStyle.Bold, GraphicsUnit.Pixel))
                    {
                        TextRenderer.DrawText(g, digits, f,
                            new Rectangle(1, 4, 12, 8), digitColor,
                            TextFormatFlags.HorizontalCenter |
                            TextFormatFlags.VerticalCenter |
                            TextFormatFlags.NoPadding);
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
        private const uint FILE_ATTRIBUTE_NORMAL = 0x80;
        private const uint FILE_FLAG_OVERLAPPED = 0x40000000;
        private const int ERROR_IO_PENDING = 998;
        private const uint WAIT_TIMEOUT = 258;
        private const uint WAIT_OBJECT_0 = 0;

        [StructLayout(LayoutKind.Sequential)]
        private struct OVERLAPPED
        {
            public uint Internal;
            public uint InternalHigh;
            public uint Offset;
            public uint OffsetHigh;
            public IntPtr hEvent;
        }

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        private static extern SafeHandle CreateFile(
            string lpFileName,
            uint dwDesiredAccess,
            uint dwShareMode,
            IntPtr lpSecurityAttributes,
            uint dwCreationDisposition,
            uint dwFlagsAndAttributes,
            IntPtr hTemplateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DeviceIoControl(
            SafeHandle hDevice,
            uint dwIoControlCode,
            IntPtr lpInBuffer,
            uint nInBufferSize,
            IntPtr lpOutBuffer,
            uint nOutBufferSize,
            out uint lpBytesReturned,
            ref OVERLAPPED lpOverlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr CreateEvent(IntPtr lpEventAttributes, bool bManualReset, bool bInitialState, string lpName);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetOverlappedResult(
            SafeHandle hDevice,
            ref OVERLAPPED lpOverlapped,
            out uint lpBytes,
            bool bWait);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        public static bool TryGetBattery(out int percent)
        {
            percent = -1;
            SafeHandle hDevice = null;
            IntPtr pOutBuffer = IntPtr.Zero;
            IntPtr hEvent = IntPtr.Zero;
            OVERLAPPED ov = new OVERLAPPED();

            try
            {
                hDevice = CreateFile(
                    @"\\.\AmtPtpControlDeviceUm",
                    GENERIC_READ | GENERIC_WRITE,
                    FILE_SHARE_READ | FILE_SHARE_WRITE,
                    IntPtr.Zero,
                    OPEN_EXISTING,
                    FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED,
                    IntPtr.Zero);

                if (hDevice == null || hDevice.IsInvalid)
                    return false;

                pOutBuffer = Marshal.AllocHGlobal(4);
                hEvent = CreateEvent(IntPtr.Zero, true, true, null);
                ov.hEvent = hEvent;

                uint bytes;
                bool issued = DeviceIoControl(
                    hDevice, IOCTL_GET_BATTERY,
                    IntPtr.Zero, 0,
                    pOutBuffer, 4,
                    out bytes,
                    ref ov);

                bool completed = issued;
                if (!completed)
                {
                    int err = Marshal.GetLastWin32Error();
                    if (err == ERROR_IO_PENDING)
                        completed = WaitForSingleObject(hEvent, 1500) == WAIT_OBJECT_0;
                }

                if (!completed)
                    return false;

                uint bytesResult;
                if (!GetOverlappedResult(hDevice, ref ov, out bytesResult, true))
                    return false;

                int v = Marshal.ReadInt32(pOutBuffer);
                if (v >= 0 && v <= 100)
                {
                    percent = v;
                    return true;
                }
                return false;
            }
            finally
            {
                if (hEvent != IntPtr.Zero)
                    CloseHandle(hEvent);
                if (pOutBuffer != IntPtr.Zero)
                    Marshal.FreeHGlobal(pOutBuffer);
                if (hDevice != null)
                    hDevice.Dispose();
            }
        }
    }
}
