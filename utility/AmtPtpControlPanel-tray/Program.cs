using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace AmtPtpControlPanel
{
    static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            if (!TrayLaunch.EnsureSingleElevatedInstance(args))
                return;

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
            Application.ThreadException +=
                (s, e) => ReportCrash(e.Exception);
            AppDomain.CurrentDomain.UnhandledException +=
                (s, e) => ReportCrash(e.ExceptionObject as Exception);

            try
            {
                Application.Run(new Main(args));
            }
            catch (Exception ex)
            {
                ReportCrash(ex);
            }
        }

        // A failure before/while the window is created used to look like
        // "nothing happens at all" - log it and say so on screen instead.
        private static void ReportCrash(Exception ex)
        {
            string log = null;
            try
            {
                string dir = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "MagicTrackpad");
                Directory.CreateDirectory(dir);
                log = Path.Combine(dir, "panel-error.log");
                File.AppendAllText(log, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss")
                    + "  " + (ex == null ? "unknown error" : ex.ToString()) + "\r\n\r\n");
            }
            catch
            {
            }

            try
            {
                MessageBox.Show(
                    "The Magic Trackpad control panel could not start:\n\n"
                    + (ex == null ? "unknown error" : ex.Message)
                    + (log == null ? "" : "\n\nDetails: " + log),
                    "Magic Trackpad", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            catch
            {
            }
        }
    }

    // Exactly one tray icon per user session, and the running instance must
    // be elevated (the driver's control device is opened by admins only).
    //
    // Relay scheme: a non-elevated launch claims the single-instance mutex,
    // frees it again, asks Windows (UAC, "RunAs" verb) to start an elevated
    // copy of itself with the flag "-relayed". The relayed copy waits for the
    // freed mutex, takes it over and signals a hand-over event; the relay copy
    // then exits silently. Refused UAC prompt -> dialog with Retry/Exit.
    public static class TrayLaunch
    {
        private const string MUTEX_NAME = "Local\\AmtPtpControlPanel.SingleInstance";
        private const string EVENT_NAME = "Local\\AmtPtpControlPanel.ElevatedStarted";
        // the running instance listens on this; a second launch sets it to ask
        // for the settings window instead of exiting silently
        public const string SHOW_EVENT_NAME = "Local\\AmtPtpControlPanel.ShowRequest";
        private const uint TOKEN_QUERY = 0x0002;
        private const int TOKEN_ELEVATION_CLASS = 2;
        private const int HANDOVER_TIMEOUT_MS = 90000;

        // keeps the mutex alive while the UI runs
        private static Mutex s_ownedMutex;

        [StructLayout(LayoutKind.Sequential)]
        private struct TOKEN_ELEVATION
        {
            public uint TokenIsElevated;
        }

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenProcessToken(IntPtr ProcessHandle, int dwDesiredAccess, out IntPtr phToken);

        [DllImport("advapi32.dll")]
        private static extern bool GetTokenInformation(IntPtr TokenHandle, int TokenInformationClass, IntPtr TokenInformation, int TokenInformationLength, out int ReturnLength);

        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr hObject);

        public static bool IsElevated()
        {
            IntPtr tok = IntPtr.Zero;
            IntPtr buf = IntPtr.Zero;
            try
            {
                if (!OpenProcessToken(GetCurrentProcess(), (int)TOKEN_QUERY, out tok))
                    return false;
                int len;
                if (!GetTokenInformation(tok, TOKEN_ELEVATION_CLASS, IntPtr.Zero, 0, out len))
                    return false;
                buf = Marshal.AllocHGlobal(len);
                if (!GetTokenInformation(tok, TOKEN_ELEVATION_CLASS, buf, len, out len))
                    return false;
                return (uint)Marshal.ReadByte(buf, 0) != 0;
            }
            catch
            {
                return false;
            }
            finally
            {
                if (buf != IntPtr.Zero)
                    Marshal.FreeHGlobal(buf);
                if (tok != IntPtr.Zero)
                    CloseHandle(tok);
            }
        }

        private static void SignalElevatedStarted()
        {
            try
            {
                EventWaitHandle ev = EventWaitHandle.OpenExisting(EVENT_NAME);
                try
                {
                    ev.Set();
                }
                finally
                {
                    ev.Dispose();
                }
            }
            catch
            {
            }
        }

        private static bool HasRelayFlag(string[] args)
        {
            if (args == null)
                return false;
            foreach (string a in args)
                if (a == "-relayed")
                    return true;
            return false;
        }

        // Waits briefly for the running instance's show-event to appear (an
        // instance that is still starting up may not have created it yet) and
        // signals it.
        private static bool RequestShowWindow()
        {
            for (int i = 0; i < 20; i++)
            {
                try
                {
                    using (EventWaitHandle ev = EventWaitHandle.OpenExisting(SHOW_EVENT_NAME))
                    {
                        ev.Set();
                        return true;
                    }
                }
                catch
                {
                    Thread.Sleep(200);
                }
            }
            return false;
        }

        private static string BuildRelayArguments(string[] args)
        {
            List<string> parts = new List<string>();
            if (args != null)
                foreach (string a in args)
                    if (!string.IsNullOrEmpty(a))
                        parts.Add("\"" + a + "\"");
            parts.Add("\"-relayed\"");
            return string.Join(" ", parts.ToArray());
        }

        public static bool EnsureSingleElevatedInstance(string[] args)
        {
            if (HasRelayFlag(args))
            {
                // UAC child: take over the mutex the relay parent freed,
                // then tell it the hand-over succeeded.
                Mutex m = new Mutex(false, MUTEX_NAME);
                bool taken = false;
                try
                {
                    taken = m.WaitOne(HANDOVER_TIMEOUT_MS);
                }
                catch
                {
                }
                if (!taken)
                    return false;
                s_ownedMutex = m;
                SignalElevatedStarted();
                m.ReleaseMutex();
                return true;
            }

            bool createdNew;
            Mutex mutex = new Mutex(false, MUTEX_NAME, out createdNew);
            Thread.MemoryBarrier();

            if (!createdNew)
            {
                // an instance is already running (tray only, window possibly
                // hidden): ask it to show its window. If it does not listen
                // (old build, or it is still starting up) say so instead of
                // exiting without any feedback.
                if (!RequestShowWindow())
                {
                    try
                    {
                        MessageBox.Show(
                            "The Magic Trackpad control panel is already running.\n\n"
                            + "It lives in the notification area - look behind the clock\n"
                            + "(click the ^ arrow next to the clock), then double-click its icon.\n\n"
                            + "If you cannot find it, end AmtPtpControlPanel.exe in Task Manager\n"
                            + "and start the panel again.",
                            "Magic Trackpad", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    }
                    catch
                    {
                    }
                }
                return false;
            }

            // we just created it (signaled state) - take it; cannot block
            mutex.WaitOne();

            if (IsElevated())
            {
                s_ownedMutex = mutex;
                SignalElevatedStarted();
                return true;
            }

            // not elevated: relay to a UAC-started elevated copy
            string exe = Process.GetCurrentProcess().MainModule.FileName;
            EventWaitHandle ev = new EventWaitHandle(false, EventResetMode.ManualReset, EVENT_NAME);

            try
            {
                while (true)
                {
                    mutex.ReleaseMutex(); // free it for the child

                    Process child = null;
                    try
                    {
                        ProcessStartInfo psi = new ProcessStartInfo(exe, BuildRelayArguments(args));
                        psi.UseShellExecute = true;
                        psi.Verb = "RunAs";
                        child = Process.Start(psi);
                    }
                    catch
                    {
                    }

                    // NEVER wait for the child to exit: the elevated copy lives for
                    // the whole session, and a relay process that lingers keeps the
                    // executable file open - that is what made the exe impossible to
                    // delete and broke uninstall. Wait for the hand-over event
                    // instead: the elevated copy signals it as soon as it owns the
                    // mutex, then this process exits immediately.
                    if (child == null)
                    {
                        // Process.Start threw - UAC was refused or the launch failed
                        if (AskRetry())
                            continue;
                        return false;
                    }

                    if (ev.WaitOne(HANDOVER_TIMEOUT_MS))
                        return false; // elevated copy is up - relay done

                    // no hand-over at all: the copy died before taking over
                    if (AskRetry())
                        continue;
                    return false;
                }
            }
            finally
            {
                ev.Dispose();
            }
        }

        private static bool AskRetry()
        {
            DialogResult r = MessageBox.Show(
                        "The Magic Trackpad control panel requires administrator rights\n" +
                        "(its settings and the driver's battery interface are admin-only).\n\n" +
                "Do you want to try again?",
                "Magic Trackpad - elevation required",
                MessageBoxButtons.RetryCancel,
                MessageBoxIcon.Warning);
            return r == DialogResult.Retry;
        }
    }
}
