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
        private bool hiddenOnStartup = false;
        private System.Windows.Forms.ToolTip tipOptions;

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
            this.FormClosed += (s, e) => DisposeTray();
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
                    "about every 15 seconds. The driver only reports the battery when " +
                    "the trackpad is connected via Bluetooth; with a USB connection " +
                    "this line shows 'not available'. The app must run elevated " +
                    "(admin), otherwise the driver's battery port cannot be opened.";

                miShowBattery = new ToolStripMenuItem("Show battery in tray");
                miShowBattery.Checked = SettingShowBattery;
                miShowBattery.CheckOnClick = true;
                miShowBattery.ToolTipText =
                    "When on, the battery percentage is drawn next to the tray icon " +
                    "(and in the line above). This works only in Bluetooth mode: in " +
                    "USB mode the menu keeps showing 'not available', because the " +
                    "USB driver does not expose the battery.";
                miShowBattery.Click += (s, e) =>
                {
                    TraySetInt("ShowBattery", miShowBattery.Checked ? 1 : 0);
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

                trayIcon = new NotifyIcon();
                trayIcon.Icon = LoadEmbeddedIcon(16);
                trayIcon.Text = "Magic Trackpad";
                trayIcon.ContextMenuStrip = trayMenu;
                trayIcon.DoubleClick += (s, e) => RestoreFromTray();
                trayIcon.Visible = true;

                trayTimer = new System.Windows.Forms.Timer();
                trayTimer.Interval = 15000;
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
                        // short Text next to the icon = the percentage itself;
                        // the full sentence stays in the menu
                        miBatteryItem.Text = "Battery: " + lastBatteryPercent + " %";
                        trayIcon.Text = lastBatteryPercent + " %";
                    }
                    else
                    {
                        miBatteryItem.Text = "Battery: not available";
                        trayIcon.Text = "Magic Trackpad";
                    }
                }
                else
                {
                    miBatteryItem.Text = "Battery: off";
                    trayIcon.Text = "Magic Trackpad";
                }
            }
            catch
            {
            }
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
