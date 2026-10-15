using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Automation;

namespace Alcove
{
    // An error whose message goes to the caller as it is.
    public sealed class HelperException : Exception
    {
        public HelperException(string message) : base(message) { }
    }

    public static class UiaHelper
    {
        const int MaxReplyBytes = 8 * 1024 * 1024 - 4096;

        const int WorkerStackBytes = 64 * 1024 * 1024;

        static readonly object outputLock = new object();
        static readonly object logLock = new object();
        static StreamWriter output;
        static StreamWriter log;
        static Exception loopFailure;

        // Serves requests from stdin until it closes. An exception that ends the serving thread
        // is thrown again here.
        public static void Run()
        {
            try { Native.SetProcessDpiAwarenessContext(new IntPtr(-4)); }
            catch (EntryPointNotFoundException) { }
            Thread worker = new Thread(GuardedLoop, WorkerStackBytes);
            worker.SetApartmentState(ApartmentState.MTA);
            worker.Start();
            worker.Join();
            if (loopFailure != null)
            {
                throw new InvalidOperationException(loopFailure.Message, loopFailure);
            }
        }

        static void GuardedLoop()
        {
            try
            {
                Loop();
            }
            catch (Exception e)
            {
                loopFailure = e;
            }
        }

        static void Loop()
        {
            try { Native.SetThreadDpiAwarenessContext(new IntPtr(-4)); }
            catch (EntryPointNotFoundException) { }
            UTF8Encoding utf8 = new UTF8Encoding(false);
            StreamReader input = new StreamReader(Console.OpenStandardInput(), utf8);
            output = new StreamWriter(Console.OpenStandardOutput(), utf8);
            output.NewLine = "\n";
            log = new StreamWriter(Console.OpenStandardError(), utf8);
            log.NewLine = "\n";
            JavaScriptSerializer parser = new JavaScriptSerializer();
            parser.MaxJsonLength = int.MaxValue;
            Session session = new Session();
            Log("started in session " + Process.GetCurrentProcess().SessionId + " at " + Native.IntegrityLevel() + " integrity");
            Send("{\"ev\":\"ready\"}");
            Thread watcher = new Thread(new WindowWatch().Run);
            watcher.IsBackground = true;
            watcher.Start();

            string line;
            while ((line = input.ReadLine()) != null)
            {
                if (line.Length == 0)
                {
                    continue;
                }
                Send(Answer(parser, session, line));
            }
        }

        static string Answer(JavaScriptSerializer parser, Session session, string line)
        {
            object id = null;
            string op = "";
            string error;
            try
            {
                Dictionary<string, object> req = Parse(parser, line);
                req.TryGetValue("id", out id);
                op = Params.Str(req, "op") ?? "";
                Dictionary<string, object> reply = new Dictionary<string, object>();
                reply["id"] = id;
                reply["ok"] = true;
                foreach (KeyValuePair<string, object> field in session.Dispatch(op, req))
                {
                    reply[field.Key] = field.Value;
                }
                string text = Json.Write(reply);
                if (text.Length * 3 <= MaxReplyBytes || Encoding.UTF8.GetByteCount(text) <= MaxReplyBytes)
                {
                    return text;
                }
                error = "the answer to '" + op + "' is larger than 8 MiB; ask for less with max, depth, limit or length";
            }
            catch (HelperException e)
            {
                error = e.Message;
            }
            catch (ElementNotAvailableException)
            {
                error = "an element disappeared while it was read; call ui.tree again";
            }
            catch (Exception e)
            {
                Log("'" + op + "' failed: " + e);
                error = "'" + op + "' failed: " + e.Message + "; see helper.log in the agent's uia folder";
            }
            Dictionary<string, object> failure = new Dictionary<string, object>();
            failure["id"] = id;
            failure["ok"] = false;
            failure["error"] = error;
            return Json.Write(failure);
        }

        static Dictionary<string, object> Parse(JavaScriptSerializer parser, string line)
        {
            Dictionary<string, object> req = null;
            try
            {
                req = parser.Deserialize<Dictionary<string, object>>(line);
            }
            catch (ArgumentException) { }
            catch (InvalidOperationException) { }
            if (req == null)
            {
                throw new HelperException("bad request: the line is not a JSON object; send one JSON object per line");
            }
            return req;
        }

        // Writes one line to stdout.
        public static void Send(string line)
        {
            lock (outputLock)
            {
                output.WriteLine(line);
                output.Flush();
            }
        }

        // Writes one line to stderr, which the agent stores in helper.log.
        public static void Log(string text)
        {
            lock (logLock)
            {
                try
                {
                    log.WriteLine(DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture)
                        + " helper " + Process.GetCurrentProcess().Id + ": " + text);
                    log.Flush();
                }
                catch (IOException) { }
            }
        }
    }

    // Typed access to request fields.
    static class Params
    {
        public static string Str(Dictionary<string, object> req, string key)
        {
            object v;
            if (!req.TryGetValue(key, out v) || v == null)
            {
                return null;
            }
            string s = v as string;
            if (s == null)
            {
                throw new HelperException("'" + key + "' must be a string");
            }
            return s;
        }

        public static bool Has(Dictionary<string, object> req, string key)
        {
            object v;
            return req.TryGetValue(key, out v) && v != null;
        }

        public static int Int(Dictionary<string, object> req, string key, int fallback)
        {
            object v;
            if (!req.TryGetValue(key, out v) || v == null)
            {
                return fallback;
            }
            if (v is int)
            {
                return (int)v;
            }
            if (v is long || v is decimal || v is double)
            {
                double d = Convert.ToDouble(v, CultureInfo.InvariantCulture);
                if (d == Math.Floor(d) && d >= int.MinValue && d <= int.MaxValue)
                {
                    return (int)d;
                }
            }
            throw new HelperException("'" + key + "' must be a whole number");
        }

        public static bool Bool(Dictionary<string, object> req, string key, bool fallback)
        {
            object v;
            if (!req.TryGetValue(key, out v) || v == null)
            {
                return fallback;
            }
            if (v is bool)
            {
                return (bool)v;
            }
            throw new HelperException("'" + key + "' must be true or false");
        }
    }

    // Writes strings, numbers, booleans, dictionaries and lists as JSON.
    static class Json
    {
        public static string Write(object value)
        {
            StringBuilder sb = new StringBuilder();
            Append(sb, value);
            return sb.ToString();
        }

        static void Append(StringBuilder sb, object v)
        {
            if (v == null)
            {
                sb.Append("null");
            }
            else if (v is string)
            {
                AppendString(sb, (string)v);
            }
            else if (v is bool)
            {
                sb.Append((bool)v ? "true" : "false");
            }
            else if (v is int || v is long || v is decimal)
            {
                sb.Append(Convert.ToString(v, CultureInfo.InvariantCulture));
            }
            else if (v is double)
            {
                double d = (double)v;
                sb.Append(double.IsNaN(d) || double.IsInfinity(d) ? "0" : d.ToString("R", CultureInfo.InvariantCulture));
            }
            else if (v is IDictionary<string, object>)
            {
                sb.Append('{');
                bool first = true;
                foreach (KeyValuePair<string, object> kv in (IDictionary<string, object>)v)
                {
                    if (!first)
                    {
                        sb.Append(',');
                    }
                    first = false;
                    AppendString(sb, kv.Key);
                    sb.Append(':');
                    Append(sb, kv.Value);
                }
                sb.Append('}');
            }
            else if (v is IEnumerable)
            {
                sb.Append('[');
                bool first = true;
                foreach (object item in (IEnumerable)v)
                {
                    if (!first)
                    {
                        sb.Append(',');
                    }
                    first = false;
                    Append(sb, item);
                }
                sb.Append(']');
            }
            else
            {
                AppendString(sb, v.ToString());
            }
        }

        static void AppendString(StringBuilder sb, string s)
        {
            sb.Append('"');
            for (int i = 0; i < s.Length; i++)
            {
                char c = s[i];
                if (c == '"' || c == '\\')
                {
                    sb.Append('\\').Append(c);
                }
                else if (c == '\n')
                {
                    sb.Append("\\n");
                }
                else if (c == '\r')
                {
                    sb.Append("\\r");
                }
                else if (c == '\t')
                {
                    sb.Append("\\t");
                }
                else if (c < 0x20 || IsLoneSurrogate(s, i))
                {
                    sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                }
                else
                {
                    sb.Append(c);
                }
            }
            sb.Append('"');
        }

        static bool IsLoneSurrogate(string s, int i)
        {
            char c = s[i];
            if (char.IsHighSurrogate(c))
            {
                return i + 1 >= s.Length || !char.IsLowSurrogate(s[i + 1]);
            }
            if (char.IsLowSurrogate(c))
            {
                return i == 0 || !char.IsHighSurrogate(s[i - 1]);
            }
            return false;
        }
    }

    static class Native
    {
        public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT
        {
            public int Left, Top, Right, Bottom;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct POINT
        {
            public int X, Y;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct MSG
        {
            public IntPtr Hwnd;
            public uint Message;
            public IntPtr WParam;
            public IntPtr LParam;
            public uint Time;
            public POINT Point;
            public uint Private;
        }

        public const int ERROR_ACCESS_DENIED = 5;
        public const int ERROR_INVALID_WINDOW_HANDLE = 1400;
        public const uint GW_OWNER = 4;
        public const uint GA_ROOT = 2;
        public const int SW_MAXIMIZE = 3;
        public const int SW_SHOWNOACTIVATE = 4;
        public const int SW_MINIMIZE = 6;
        public const int SW_RESTORE = 9;
        public const uint WM_NULL = 0;
        public const uint WM_CLOSE = 0x0010;
        public const uint SMTO_ABORTIFHUNG = 0x0002;
        public const uint SWP_NOSIZE = 0x0001;
        public const uint SWP_NOMOVE = 0x0002;
        public const uint SWP_NOZORDER = 0x0004;
        public const uint SWP_NOACTIVATE = 0x0010;
        public const uint SWP_ASYNCWINDOWPOS = 0x4000;
        public const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;
        public const int DWMWA_CLOAKED = 14;

        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool IsHungAppWindow(IntPtr hwnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hwnd, StringBuilder text, int max);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hwnd, StringBuilder text, int max);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern IntPtr GetDesktopWindow();
        [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hwnd, uint cmd);
        [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
        [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT point);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
        [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
        [DllImport("user32.dll")] public static extern IntPtr HungWindowFromGhostWindow(IntPtr ghost);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr hwnd, bool altTab);
        [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hwnd, int command);
        [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint from, uint to, bool attach);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool PostMessageW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool PeekMessageW(out MSG message, IntPtr hwnd, uint min, uint max, uint remove);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern IntPtr SendMessageTimeoutW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
        [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
        [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
        [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
        [DllImport("user32.dll")] public static extern IntPtr GetThreadDpiAwarenessContext();
        [DllImport("user32.dll")] public static extern int GetAwarenessFromDpiAwarenessContext(IntPtr context);
        [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out RECT value, int size);
        [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out int value, int size);
        [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
        [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern bool QueryFullProcessImageNameW(IntPtr process, uint flags, StringBuilder name, ref uint size);
        [DllImport("advapi32.dll")] public static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll")] public static extern bool GetTokenInformation(IntPtr token, int cls, IntPtr info, uint length, out uint needed);
        [DllImport("advapi32.dll")] public static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);
        [DllImport("advapi32.dll")] public static extern IntPtr GetSidSubAuthority(IntPtr sid, uint index);

        // The top-level window that contains the foreground window, or zero.
        public static IntPtr ForegroundWindow()
        {
            IntPtr hwnd = GetForegroundWindow();
            if (hwnd == IntPtr.Zero)
            {
                return hwnd;
            }
            IntPtr root = GetAncestor(hwnd, GA_ROOT);
            return root != IntPtr.Zero ? root : hwnd;
        }

        // The integrity level of this process: low, medium, high, system or unknown.
        public static string IntegrityLevel()
        {
            IntPtr token;
            if (!OpenProcessToken(GetCurrentProcess(), 8, out token))
            {
                return "unknown";
            }
            try
            {
                uint needed;
                GetTokenInformation(token, 25, IntPtr.Zero, 0, out needed);
                if (needed == 0)
                {
                    return "unknown";
                }
                IntPtr buffer = Marshal.AllocHGlobal((int)needed);
                try
                {
                    if (!GetTokenInformation(token, 25, buffer, needed, out needed))
                    {
                        return "unknown";
                    }
                    IntPtr sid = Marshal.ReadIntPtr(buffer);
                    int count = Marshal.ReadByte(GetSidSubAuthorityCount(sid));
                    int rid = Marshal.ReadInt32(GetSidSubAuthority(sid, (uint)(count - 1)));
                    if (rid >= 0x4000) { return "system"; }
                    if (rid >= 0x3000) { return "high"; }
                    if (rid >= 0x2000) { return "medium"; }
                    return "low";
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
            finally
            {
                CloseHandle(token);
            }
        }

        // The DPI awareness of the calling thread: unaware, system or per-monitor.
        public static string DpiAwareness()
        {
            try
            {
                int a = GetAwarenessFromDpiAwarenessContext(GetThreadDpiAwarenessContext());
                return a == 2 ? "per-monitor" : a == 1 ? "system" : "unaware";
            }
            catch (EntryPointNotFoundException)
            {
                return "unaware";
            }
        }
    }

    sealed class RefEntry
    {
        public int Number;
        public string Key;
        public AutomationElement Element;
        public IntPtr Window;
        public long Used;
    }

    sealed class Selector
    {
        public string Window;
        public string Role;
        public string Name;
        public string NameContains;
        public string AutomationId;
        public int Index = -1;

        public bool HasCriteria
        {
            get { return Role != null || Name != null || NameContains != null || AutomationId != null; }
        }

        public string ToJson()
        {
            Dictionary<string, object> d = new Dictionary<string, object>();
            if (Window != null) { d["window"] = Window; }
            if (Role != null) { d["role"] = Role; }
            if (Name != null) { d["name"] = Name; }
            if (NameContains != null) { d["nameContains"] = NameContains; }
            if (AutomationId != null) { d["automationId"] = AutomationId; }
            if (Index >= 0) { d["index"] = Index; }
            return Json.Write(d);
        }
    }

    // Compares the titled windows every 300 ms and writes an event for each difference.
    sealed class WindowWatch
    {
        const int IntervalMs = 300;
        const long EventCapMs = 1000;
        const long FailureLogMs = 60000;

        Dictionary<IntPtr, Dictionary<string, object>> known = new Dictionary<IntPtr, Dictionary<string, object>>();
        // Per window: the title of the last window.title (or the title the window had when it
        // was first compared) and the time of that event.
        readonly Dictionary<IntPtr, string> lastTitleSent = new Dictionary<IntPtr, string>();
        readonly Dictionary<IntPtr, long> titleSentAt = new Dictionary<IntPtr, long>();
        // The window the last window.foreground named (or the one in front at the first
        // comparison), zero once that window no longer exists, and, per window, the time of its
        // last window.foreground.
        IntPtr foregroundSent;
        readonly Dictionary<IntPtr, long> foregroundSentAt = new Dictionary<IntPtr, long>();
        readonly Stopwatch clock = Stopwatch.StartNew();
        long lastFailureLog = -FailureLogMs;

        public void Run()
        {
            try { Native.SetThreadDpiAwarenessContext(new IntPtr(-4)); }
            catch (EntryPointNotFoundException) { }
            try
            {
                Compare(false);
            }
            catch (Exception e)
            {
                UiaHelper.Log("the first window comparison failed: " + e);
            }
            while (true)
            {
                Thread.Sleep(IntervalMs);
                try
                {
                    Compare(true);
                }
                catch (Exception e)
                {
                    long now = clock.ElapsedMilliseconds;
                    if (now - lastFailureLog >= FailureLogMs)
                    {
                        lastFailureLog = now;
                        UiaHelper.Log("the window comparison failed: " + e);
                    }
                }
            }
        }

        void Compare(bool report)
        {
            long now = clock.ElapsedMilliseconds;
            IntPtr front = Native.ForegroundWindow();
            Dictionary<IntPtr, Dictionary<string, object>> windows = new Dictionary<IntPtr, Dictionary<string, object>>();
            List<IntPtr> order = new List<IntPtr>();
            foreach (IntPtr hwnd in Session.ListedWindows(front))
            {
                Dictionary<string, object> window = Session.WindowObject(hwnd, front);
                if (((string)window["title"]).Length > 0)
                {
                    windows[hwnd] = window;
                    order.Add(hwnd);
                }
            }
            if (report)
            {
                foreach (KeyValuePair<IntPtr, Dictionary<string, object>> old in known)
                {
                    if (!windows.ContainsKey(old.Key))
                    {
                        old.Value["foreground"] = false;
                        Emit("window.closed", old.Value);
                        lastTitleSent.Remove(old.Key);
                        titleSentAt.Remove(old.Key);
                    }
                }
            }
            foreach (IntPtr hwnd in order)
            {
                Dictionary<string, object> window = windows[hwnd];
                string title = (string)window["title"];
                if (!known.ContainsKey(hwnd))
                {
                    if (report)
                    {
                        Emit("window.opened", window);
                        if ((bool)window["modal"] || (string)window["class"] == "#32770")
                        {
                            Emit("dialog.opened", window);
                        }
                    }
                    lastTitleSent[hwnd] = title;
                }
                else if (report)
                {
                    MaybeEmitTitle(hwnd, title, window, now);
                }
            }
            ForgetClosedForeground();
            if (!report)
            {
                foregroundSent = front;
            }
            else if (front != IntPtr.Zero && front != foregroundSent)
            {
                // A window is announced at most once per EventCapMs, except when the window the
                // last event named no longer exists.
                long last;
                if (foregroundSent == IntPtr.Zero || !foregroundSentAt.TryGetValue(front, out last) || now - last >= EventCapMs)
                {
                    Dictionary<string, object> window;
                    if (!windows.TryGetValue(front, out window))
                    {
                        window = Session.WindowObject(front, front);
                    }
                    Emit("window.foreground", window);
                    foregroundSent = front;
                    foregroundSentAt[front] = now;
                }
            }
            known = windows;
        }

        // Emits window.title when the title differs from the one last sent for the window and at
        // least a second has passed since the window's last window.title.
        void MaybeEmitTitle(IntPtr hwnd, string title, Dictionary<string, object> window, long now)
        {
            string sent;
            if (lastTitleSent.TryGetValue(hwnd, out sent) && sent == title)
            {
                return;
            }
            long last;
            if (titleSentAt.TryGetValue(hwnd, out last) && now - last < EventCapMs)
            {
                return;
            }
            Emit("window.title", window);
            lastTitleSent[hwnd] = title;
            titleSentAt[hwnd] = now;
        }

        // Drops the foreground state of windows that no longer exist.
        void ForgetClosedForeground()
        {
            List<IntPtr> gone = null;
            foreach (IntPtr hwnd in foregroundSentAt.Keys)
            {
                if (!Native.IsWindow(hwnd))
                {
                    if (gone == null)
                    {
                        gone = new List<IntPtr>();
                    }
                    gone.Add(hwnd);
                }
            }
            if (gone != null)
            {
                foreach (IntPtr hwnd in gone)
                {
                    foregroundSentAt.Remove(hwnd);
                }
            }
            if (foregroundSent != IntPtr.Zero && !Native.IsWindow(foregroundSent))
            {
                foregroundSent = IntPtr.Zero;
            }
        }

        static void Emit(string name, Dictionary<string, object> window)
        {
            Dictionary<string, object> ev = new Dictionary<string, object>();
            ev["ev"] = name;
            ev["window"] = window;
            UiaHelper.Send(Json.Write(ev));
        }
    }

    // The state of one helper process: element refs and the ops.
    sealed class Session
    {
        const int MaxRefs = 20000;
        const int RefsPerStart = 1000000;
        const int DefaultTreeMax = 300;
        const int TreeMaxCap = 2000;
        const int DefaultTreeDepth = 12;
        const int TreeBudgetMs = 20000;
        const int FindBudgetMs = 12000;
        const int TextBudgetMs = 22000;
        const int DefaultFindLimit = 20;
        const int TextCap = 200000;
        const int ValueCut = 200;
        const int MaxWalkDepth = 256;
        const int RespondMs = 2000;
        const int WindowStateMs = 2000;
        const int CloseWaitMs = 2000;
        const int ForegroundStepMs = 400;
        const int ActWaitMs = 1500;
        const int ActSettleMs = 100;
        const int ActRespondMs = 500;
        const int RefGoneWaitMs = 500;

        readonly Dictionary<string, RefEntry> refsByKey = new Dictionary<string, RefEntry>();
        readonly Dictionary<int, RefEntry> refsByNumber = new Dictionary<int, RefEntry>();
        int nextRef = 1;
        long clock;
        // The top-level window of the elements the running request lists or acts on, or zero.
        IntPtr scopeWindow;

        readonly CacheRequest nodeCacheControl;
        readonly CacheRequest nodeCacheRaw;
        readonly CacheRequest matchCache;
        readonly CacheRequest textCache;
        readonly Stopwatch watch = new Stopwatch();
        int budgetMs;
        readonly Dictionary<string, ControlType> rolesByName = new Dictionary<string, ControlType>(StringComparer.OrdinalIgnoreCase);
        readonly HashSet<ControlType> interactiveTypes = new HashSet<ControlType>();

        const string PasswordSentence = "the element is a password field; its text is not read; it cannot be read through UI Automation";

        const int MaxActThreadsPerApp = 8;
        static readonly object actLock = new object();
        static readonly Dictionary<int, int> actThreads = new Dictionary<int, int>();

        public Session()
        {
            int start;
            if (int.TryParse(Environment.GetEnvironmentVariable("ALCOVE_UIA_START"), NumberStyles.None, CultureInfo.InvariantCulture, out start))
            {
                nextRef = (start % 2000) * RefsPerStart + 1;
            }
            nodeCacheControl = NodeCache(Automation.ControlViewCondition);
            nodeCacheRaw = NodeCache(Automation.RawViewCondition);
            matchCache = new CacheRequest();
            matchCache.TreeFilter = Automation.ControlViewCondition;
            matchCache.Add(AutomationElement.NameProperty);
            matchCache.Add(AutomationElement.ControlTypeProperty);
            matchCache.Add(AutomationElement.AutomationIdProperty);
            matchCache.Add(AutomationElement.IsPasswordProperty);
            textCache = new CacheRequest();
            textCache.TreeFilter = Automation.ControlViewCondition;
            textCache.Add(AutomationElement.NameProperty);
            textCache.Add(AutomationElement.ControlTypeProperty);
            textCache.Add(AutomationElement.IsPasswordProperty);
            textCache.Add(ValuePattern.ValueProperty);
            foreach (FieldInfo field in typeof(ControlType).GetFields(BindingFlags.Public | BindingFlags.Static))
            {
                ControlType type = field.GetValue(null) as ControlType;
                if (type != null)
                {
                    rolesByName[field.Name] = type;
                }
            }
            interactiveTypes.Add(ControlType.Button);
            interactiveTypes.Add(ControlType.CheckBox);
            interactiveTypes.Add(ControlType.ComboBox);
            interactiveTypes.Add(ControlType.DataItem);
            interactiveTypes.Add(ControlType.Document);
            interactiveTypes.Add(ControlType.Edit);
            interactiveTypes.Add(ControlType.HeaderItem);
            interactiveTypes.Add(ControlType.Hyperlink);
            interactiveTypes.Add(ControlType.ListItem);
            interactiveTypes.Add(ControlType.MenuItem);
            interactiveTypes.Add(ControlType.RadioButton);
            interactiveTypes.Add(ControlType.Slider);
            interactiveTypes.Add(ControlType.Spinner);
            interactiveTypes.Add(ControlType.SplitButton);
            interactiveTypes.Add(ControlType.TabItem);
            interactiveTypes.Add(ControlType.TreeItem);
        }

        static CacheRequest NodeCache(Condition view)
        {
            CacheRequest r = new CacheRequest();
            r.TreeFilter = view;
            r.Add(AutomationElement.NameProperty);
            r.Add(AutomationElement.ControlTypeProperty);
            r.Add(AutomationElement.AutomationIdProperty);
            r.Add(AutomationElement.BoundingRectangleProperty);
            r.Add(AutomationElement.IsEnabledProperty);
            r.Add(AutomationElement.IsOffscreenProperty);
            r.Add(AutomationElement.HasKeyboardFocusProperty);
            r.Add(AutomationElement.IsKeyboardFocusableProperty);
            r.Add(AutomationElement.IsPasswordProperty);
            r.Add(AutomationElement.IsInvokePatternAvailableProperty);
            r.Add(ValuePattern.ValueProperty);
            r.Add(TogglePattern.ToggleStateProperty);
            r.Add(SelectionItemPattern.IsSelectedProperty);
            r.Add(ExpandCollapsePattern.ExpandCollapseStateProperty);
            return r;
        }

        public Dictionary<string, object> Dispatch(string op, Dictionary<string, object> req)
        {
            watch.Restart();
            budgetMs = op == "ui.tree" ? TreeBudgetMs : op == "ui.text" ? TextBudgetMs : FindBudgetMs;
            scopeWindow = IntPtr.Zero;
            switch (op)
            {
                case "ping": return Ping();
                case "win.list": return WinList();
                case "win.action": return WinAction(req);
                case "ui.act": return UiAct(req);
                case "ui.tree": return UiTree(req);
                case "ui.find": return UiFind(req);
                case "ui.text": return UiText(req);
                case "ui.rect": return UiRect(req);
                case "ui.focused": return UiFocused();
                case "ui.at": return UiAt(req);
                default: throw new HelperException("unknown op '" + op + "'; update alcove-agent");
            }
        }

        Dictionary<string, object> Ping()
        {
            Dictionary<string, object> r = new Dictionary<string, object>();
            Process self = Process.GetCurrentProcess();
            r["pong"] = true;
            r["clr"] = Environment.Version.ToString();
            r["pid"] = self.Id;
            r["session"] = self.SessionId;
            r["integrity"] = Native.IntegrityLevel();
            r["dpi"] = Native.DpiAwareness();
            r["refs"] = refsByNumber.Count;
            return r;
        }

        // ---- windows ----

        Dictionary<string, object> WinList()
        {
            IntPtr foreground = Native.ForegroundWindow();
            List<object> windows = new List<object>();
            foreach (IntPtr hwnd in ListedWindows(foreground))
            {
                windows.Add(WindowObject(hwnd, foreground));
            }
            Dictionary<string, object> r = new Dictionary<string, object>();
            r["windows"] = windows;
            return r;
        }

        // Top-level windows in z-order that are shown and titled, plus the foreground window.
        internal static List<IntPtr> ListedWindows(IntPtr foreground)
        {
            List<IntPtr> all = new List<IntPtr>();
            Native.EnumWindows(delegate(IntPtr hwnd, IntPtr lParam) { all.Add(hwnd); return true; }, IntPtr.Zero);
            List<IntPtr> listed = new List<IntPtr>();
            foreach (IntPtr hwnd in all)
            {
                if (hwnd == foreground || (Native.IsWindowVisible(hwnd) && !IsCloaked(hwnd) && WindowTitle(hwnd).Length > 0))
                {
                    listed.Add(hwnd);
                }
            }
            return listed;
        }

        static bool IsCloaked(IntPtr hwnd)
        {
            int cloaked;
            return Native.DwmGetWindowAttribute(hwnd, Native.DWMWA_CLOAKED, out cloaked, 4) == 0 && cloaked != 0;
        }

        internal static string WindowTitle(IntPtr hwnd)
        {
            StringBuilder sb = new StringBuilder(1024);
            Native.GetWindowTextW(hwnd, sb, sb.Capacity);
            return sb.ToString();
        }

        static string WindowClass(IntPtr hwnd)
        {
            StringBuilder sb = new StringBuilder(256);
            Native.GetClassNameW(hwnd, sb, sb.Capacity);
            return sb.ToString();
        }

        static string ProcessImage(uint pid)
        {
            IntPtr process = Native.OpenProcess(0x1000, false, pid);
            if (process == IntPtr.Zero)
            {
                return "";
            }
            try
            {
                StringBuilder sb = new StringBuilder(1024);
                uint size = (uint)sb.Capacity;
                if (!Native.QueryFullProcessImageNameW(process, 0, sb, ref size))
                {
                    return "";
                }
                return Path.GetFileName(sb.ToString());
            }
            finally
            {
                Native.CloseHandle(process);
            }
        }

        internal static string HwndId(IntPtr hwnd)
        {
            return "0x" + hwnd.ToInt64().ToString("x", CultureInfo.InvariantCulture);
        }

        internal static Dictionary<string, object> WindowObject(IntPtr hwnd, IntPtr foreground)
        {
            Dictionary<string, object> w = new Dictionary<string, object>();
            string cls = WindowClass(hwnd);
            uint pid;
            Native.GetWindowThreadProcessId(hwnd, out pid);
            if (cls == "ApplicationFrameWindow")
            {
                // The frame window of a packaged app reports the process of its core window.
                IntPtr core = Native.FindWindowExW(hwnd, IntPtr.Zero, "Windows.UI.Core.CoreWindow", null);
                uint corePid;
                if (core != IntPtr.Zero && Native.GetWindowThreadProcessId(core, out corePid) != 0 && corePid != 0)
                {
                    pid = corePid;
                }
            }
            else if (cls == "Ghost")
            {
                // The window the system shows in place of a window that stopped responding reports that window's process.
                try
                {
                    IntPtr hung = Native.HungWindowFromGhostWindow(hwnd);
                    uint hungPid;
                    if (hung != IntPtr.Zero && Native.GetWindowThreadProcessId(hung, out hungPid) != 0 && hungPid != 0)
                    {
                        pid = hungPid;
                    }
                }
                catch (EntryPointNotFoundException) { }
            }
            bool minimized = Native.IsIconic(hwnd);
            Native.RECT rect = new Native.RECT();
            if (!minimized && Native.DwmGetWindowAttribute(hwnd, Native.DWMWA_EXTENDED_FRAME_BOUNDS, out rect, 16) != 0)
            {
                Native.GetWindowRect(hwnd, out rect);
            }
            IntPtr owner = Native.GetWindow(hwnd, Native.GW_OWNER);
            w["id"] = HwndId(hwnd);
            w["title"] = WindowTitle(hwnd);
            w["pid"] = (long)pid;
            w["process"] = ProcessImage(pid);
            w["class"] = cls;
            w["x"] = rect.Left;
            w["y"] = rect.Top;
            w["w"] = rect.Right - rect.Left;
            w["h"] = rect.Bottom - rect.Top;
            w["state"] = minimized ? "minimized" : Native.IsZoomed(hwnd) ? "maximized" : "normal";
            w["foreground"] = hwnd == foreground;
            w["responding"] = !Native.IsHungAppWindow(hwnd);
            w["modal"] = owner != IntPtr.Zero && Native.IsWindow(owner) && !Native.IsWindowEnabled(owner);
            return w;
        }

        // Resolves a window id, "foreground" or a title part to a window handle.
        static IntPtr ResolveWindow(string window)
        {
            IntPtr foreground = Native.ForegroundWindow();
            if (window == null || window == "foreground")
            {
                if (foreground == IntPtr.Zero)
                {
                    throw new HelperException("no window is in the foreground; pass a window id from win.list");
                }
                return foreground;
            }
            if (window.Length == 0)
            {
                throw new HelperException("pass a window id, a title part, or foreground");
            }
            if (window.StartsWith("0x", StringComparison.OrdinalIgnoreCase))
            {
                long value;
                if (window.Length < 3 || window.Length > 18
                    || !long.TryParse(window.Substring(2), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out value))
                {
                    throw new HelperException(Json.Write(window) + " is not a window id; ids look like 0x1a2b3c and come from win.list");
                }
                IntPtr hwnd = new IntPtr(value);
                if (!Native.IsWindow(hwnd) || Native.GetAncestor(hwnd, Native.GA_ROOT) != hwnd)
                {
                    throw new HelperException("window " + window + " no longer exists; call win.list again");
                }
                return hwnd;
            }
            foreach (IntPtr hwnd in ListedWindows(foreground))
            {
                if (WindowTitle(hwnd).IndexOf(window, StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    return hwnd;
                }
            }
            throw new HelperException("no window has " + Json.Write(window) + " in its title; call win.list to see the open windows");
        }

        // True when ResolveWindow gives hwnd for the title.
        static bool TitleResolvesTo(string title, IntPtr hwnd)
        {
            try
            {
                return ResolveWindow(title) == hwnd;
            }
            catch (HelperException)
            {
                return false;
            }
        }

        // The top-level window that contains the element, or zero.
        static IntPtr TopWindow(AutomationElement element)
        {
            AutomationElement current = element;
            for (int i = 0; i < 64 && current != null; i++)
            {
                int handle = (int)current.GetCurrentPropertyValue(AutomationElement.NativeWindowHandleProperty);
                if (handle != 0)
                {
                    IntPtr root = Native.GetAncestor(new IntPtr(handle), Native.GA_ROOT);
                    return root != IntPtr.Zero ? root : new IntPtr(handle);
                }
                current = TreeWalker.RawViewWalker.GetParent(current);
            }
            return IntPtr.Zero;
        }

        // TopWindow of the element, or zero when the element or a parent cannot be read.
        static IntPtr TopWindowOrZero(AutomationElement element)
        {
            try
            {
                return TopWindow(element);
            }
            catch (ElementNotAvailableException) { }
            catch (InvalidOperationException) { }
            catch (COMException) { }
            catch (System.ComponentModel.Win32Exception) { }
            catch (UnauthorizedAccessException) { }
            return IntPtr.Zero;
        }

        // True for the window the system shows in place of a window that stopped responding.
        static bool IsGhostOfHungWindow(IntPtr hwnd)
        {
            try
            {
                return Native.HungWindowFromGhostWindow(hwnd) != IntPtr.Zero;
            }
            catch (EntryPointNotFoundException)
            {
                return false;
            }
        }

        static object WindowObjectOrNull(IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero || !Native.IsWindow(hwnd))
            {
                return null;
            }
            return WindowObject(hwnd, Native.ForegroundWindow());
        }

        // True when the window's thread handles a message within the given time or the message
        // is denied with access denied.
        static bool Responds(IntPtr hwnd, int ms)
        {
            IntPtr result;
            if (Native.SendMessageTimeoutW(hwnd, Native.WM_NULL, IntPtr.Zero, IntPtr.Zero, Native.SMTO_ABORTIFHUNG, (uint)ms, out result) != IntPtr.Zero)
            {
                return true;
            }
            return Marshal.GetLastWin32Error() == Native.ERROR_ACCESS_DENIED;
        }

        static void RequireResponding(IntPtr hwnd)
        {
            if (Native.IsHungAppWindow(hwnd) || (Native.IsWindow(hwnd) && !Responds(hwnd, RespondMs)))
            {
                throw new HelperException("window " + HwndId(hwnd) + " " + Json.Write(WindowTitle(hwnd))
                    + " is not responding; wait and retry, or end its process with proc.kill when win.list still shows responding false after 10 s");
            }
        }

        static AutomationElement WindowElement(IntPtr hwnd, CacheRequest cache)
        {
            RequireResponding(hwnd);
            try
            {
                using (cache.Activate())
                {
                    return AutomationElement.FromHandle(hwnd);
                }
            }
            catch (ElementNotAvailableException)
            {
                throw new HelperException("window " + HwndId(hwnd) + " no longer exists; call win.list again");
            }
        }

        // ---- win.action ----

        static bool WaitUntil(Func<bool> done, int ms)
        {
            Stopwatch waited = Stopwatch.StartNew();
            while (!done())
            {
                if (waited.ElapsedMilliseconds >= ms)
                {
                    return false;
                }
                Thread.Sleep(20);
            }
            return true;
        }

        // The sentence for a show-state change that did not take: it names proc.kill for a window
        // that is hung and win.list for one that answers messages.
        static string NotChanged(IntPtr hwnd, string what)
        {
            string head = "window " + HwndId(hwnd) + " " + Json.Write(WindowTitle(hwnd)) + " " + what + " within " + (WindowStateMs / 1000) + " s; ";
            if (Native.IsHungAppWindow(hwnd) || (Native.IsWindow(hwnd) && !Responds(hwnd, RespondMs)))
            {
                return head + "check responding in win.list, then retry or end its process with proc.kill";
            }
            return head + "the app may not allow it; use win.list to see its state";
        }

        // Asks the window to change its show state and waits until it has.
        static void Show(IntPtr hwnd, int command, Func<bool> done, string what)
        {
            if (done())
            {
                return;
            }
            Native.ShowWindowAsync(hwnd, command);
            if (!WaitUntil(done, WindowStateMs))
            {
                throw new HelperException(NotChanged(hwnd, what));
            }
        }

        static void ShowNormal(IntPtr hwnd)
        {
            Show(hwnd, Native.SW_SHOWNOACTIVATE, delegate { return !Native.IsIconic(hwnd) && !Native.IsZoomed(hwnd); }, "did not return to its normal size");
        }

        static bool IsForeground(IntPtr hwnd)
        {
            return Native.ForegroundWindow() == hwnd;
        }

        // Brings the window to the foreground: SetForegroundWindow first, then the same call with this
        // thread's input attached to the foreground window's thread, then SwitchToThisWindow. A
        // minimized window is restored first.
        static void Focus(IntPtr hwnd)
        {
            Show(hwnd, Native.SW_RESTORE, delegate { return !Native.IsIconic(hwnd); }, "did not leave the minimized state");
            if (IsForeground(hwnd))
            {
                return;
            }
            string step = "SetForegroundWindow";
            if (!Native.SetForegroundWindow(hwnd) || !WaitUntil(delegate { return IsForeground(hwnd); }, ForegroundStepMs))
            {
                step = "SetForegroundWindow with attached input";
                IntPtr current = Native.ForegroundWindow();
                uint ignored;
                uint self = Native.GetCurrentThreadId();
                uint other = current == IntPtr.Zero || Native.IsHungAppWindow(current) ? 0 : Native.GetWindowThreadProcessId(current, out ignored);
                Native.MSG message;
                Native.PeekMessageW(out message, IntPtr.Zero, 0, 0, 0);
                bool attached = other != 0 && other != self && Native.AttachThreadInput(self, other, true);
                try
                {
                    Native.BringWindowToTop(hwnd);
                    Native.SetForegroundWindow(hwnd);
                }
                finally
                {
                    if (attached)
                    {
                        Native.AttachThreadInput(self, other, false);
                    }
                }
                if (!WaitUntil(delegate { return IsForeground(hwnd); }, ForegroundStepMs))
                {
                    step = "SwitchToThisWindow";
                    Native.SwitchToThisWindow(hwnd, true);
                    if (!WaitUntil(delegate { return IsForeground(hwnd); }, ForegroundStepMs))
                    {
                        throw new HelperException("window " + HwndId(hwnd) + " " + Json.Write(WindowTitle(hwnd))
                            + " did not come to the foreground; click its title bar through the display");
                    }
                }
            }
            UiaHelper.Log("window " + HwndId(hwnd) + " came to the foreground through " + step);
        }

        static void Frame(IntPtr hwnd, out Native.RECT outer, out Native.RECT visible)
        {
            Native.GetWindowRect(hwnd, out outer);
            if (Native.DwmGetWindowAttribute(hwnd, Native.DWMWA_EXTENDED_FRAME_BOUNDS, out visible, 16) != 0)
            {
                visible = outer;
            }
        }

        Dictionary<string, object> WinAction(Dictionary<string, object> req)
        {
            string action = Params.Str(req, "action");
            string window = Params.Str(req, "window");
            if (window == null)
            {
                throw new HelperException("pass window: a window id from win.list, a title part, or foreground");
            }
            IntPtr hwnd = ResolveWindow(window);
            Dictionary<string, object> r = new Dictionary<string, object>();
            switch (action)
            {
                case "focus":
                    Focus(hwnd);
                    break;
                case "minimize":
                    Show(hwnd, Native.SW_MINIMIZE, delegate { return Native.IsIconic(hwnd); }, "was not minimized");
                    break;
                case "maximize":
                    Show(hwnd, Native.SW_MAXIMIZE, delegate { return Native.IsZoomed(hwnd) && !Native.IsIconic(hwnd); }, "was not maximized");
                    break;
                case "restore":
                {
                    bool minimized = Native.IsIconic(hwnd);
                    Show(hwnd, Native.SW_RESTORE, delegate { return minimized ? !Native.IsIconic(hwnd) : !Native.IsZoomed(hwnd); },
                        minimized ? "did not leave the minimized state" : "did not leave the maximized state");
                    break;
                }
                case "close":
                {
                    string cls = WindowClass(hwnd);
                    if (cls == "Progman" || cls == "WorkerW" || cls == "Shell_TrayWnd" || cls == "Shell_SecondaryTrayWnd")
                    {
                        throw new HelperException("window " + HwndId(hwnd) + " is part of the Windows shell and is not closed; close app windows only");
                    }
                    if (!Native.PostMessageW(hwnd, Native.WM_CLOSE, IntPtr.Zero, IntPtr.Zero))
                    {
                        int code = Marshal.GetLastWin32Error();
                        if (code == Native.ERROR_INVALID_WINDOW_HANDLE)
                        {
                            r["closed"] = true;
                            r["window"] = null;
                            return r;
                        }
                        if (code == Native.ERROR_ACCESS_DENIED)
                        {
                            throw new HelperException("window " + HwndId(hwnd) + " belongs to a process the helper cannot send to; run the app without elevation or use input ops");
                        }
                        throw new HelperException("window " + HwndId(hwnd) + " could not be asked to close (error " + code + "); retry");
                    }
                    r["closed"] = WaitUntil(delegate { return !Native.IsWindow(hwnd) || !Native.IsWindowVisible(hwnd); }, CloseWaitMs);
                    break;
                }
                case "move":
                case "resize":
                {
                    bool move = action == "move";
                    string first = move ? "x" : "w", second = move ? "y" : "h";
                    if (!Params.Has(req, first) || !Params.Has(req, second))
                    {
                        throw new HelperException(action + " needs " + first + " and " + second);
                    }
                    int a = Params.Int(req, first, 0), b = Params.Int(req, second, 0);
                    if (!move && (a < 1 || b < 1))
                    {
                        throw new HelperException("pass w and h of at least 1");
                    }
                    ShowNormal(hwnd);
                    Native.RECT outer, visible;
                    Frame(hwnd, out outer, out visible);
                    uint flags = Native.SWP_NOZORDER | Native.SWP_NOACTIVATE | Native.SWP_ASYNCWINDOWPOS;
                    if (move)
                    {
                        Native.SetWindowPos(hwnd, IntPtr.Zero, a - (visible.Left - outer.Left), b - (visible.Top - outer.Top), 0, 0, flags | Native.SWP_NOSIZE);
                    }
                    else
                    {
                        int extraW = (outer.Right - outer.Left) - (visible.Right - visible.Left);
                        int extraH = (outer.Bottom - outer.Top) - (visible.Bottom - visible.Top);
                        Native.SetWindowPos(hwnd, IntPtr.Zero, 0, 0, a + extraW, b + extraH, flags | Native.SWP_NOMOVE);
                    }
                    Native.RECT was = outer;
                    WaitUntil(delegate
                    {
                        Native.RECT now, shown;
                        Frame(hwnd, out now, out shown);
                        bool changed = now.Left != was.Left || now.Top != was.Top || now.Right != was.Right || now.Bottom != was.Bottom;
                        bool asked = move ? shown.Left == a && shown.Top == b : shown.Right - shown.Left == a && shown.Bottom - shown.Top == b;
                        return changed || asked;
                    }, WindowStateMs);
                    break;
                }
                default:
                    throw new HelperException("action must be one of focus, minimize, maximize, restore, close, move, resize");
            }
            r["window"] = Native.IsWindow(hwnd) && Native.IsWindowVisible(hwnd) ? WindowObject(hwnd, Native.ForegroundWindow()) : null;
            return r;
        }

        // ---- ui.act ----

        static readonly string[] actions = { "invoke", "toggle", "expand", "collapse", "select", "set_value", "focus", "scroll_into_view" };

        // The ui.act actions the element supports.
        static List<string> SupportedActions(AutomationElement element)
        {
            List<string> supported = new List<string>();
            object pattern;
            if (element.TryGetCurrentPattern(InvokePattern.Pattern, out pattern)) { supported.Add("invoke"); }
            if (element.TryGetCurrentPattern(TogglePattern.Pattern, out pattern)) { supported.Add("toggle"); }
            if (element.TryGetCurrentPattern(ExpandCollapsePattern.Pattern, out pattern)) { supported.Add("expand"); supported.Add("collapse"); }
            if (element.TryGetCurrentPattern(SelectionItemPattern.Pattern, out pattern)) { supported.Add("select"); }
            if (element.TryGetCurrentPattern(ValuePattern.Pattern, out pattern)) { supported.Add("set_value"); }
            if (CachedBool(element, AutomationElement.IsKeyboardFocusableProperty)) { supported.Add("focus"); }
            if (element.TryGetCurrentPattern(ScrollItemPattern.Pattern, out pattern)) { supported.Add("scroll_into_view"); }
            return supported;
        }

        static object PatternFor(AutomationElement element, AutomationPattern pattern, string action)
        {
            object found;
            if (element.TryGetCurrentPattern(pattern, out found))
            {
                return found;
            }
            List<string> supported = SupportedActions(element);
            throw new HelperException("the element does not support " + action + "; "
                + (supported.Count > 0 ? "it supports " + string.Join(", ", supported.ToArray()) : "it supports no ui.act action")
                + "; click it through the display for anything else");
        }

        static void Perform(AutomationElement element, string action, string value)
        {
            switch (action)
            {
                case "invoke":
                    ((InvokePattern)PatternFor(element, InvokePattern.Pattern, action)).Invoke();
                    break;
                case "toggle":
                    ((TogglePattern)PatternFor(element, TogglePattern.Pattern, action)).Toggle();
                    break;
                case "expand":
                    ((ExpandCollapsePattern)PatternFor(element, ExpandCollapsePattern.Pattern, action)).Expand();
                    break;
                case "collapse":
                    ((ExpandCollapsePattern)PatternFor(element, ExpandCollapsePattern.Pattern, action)).Collapse();
                    break;
                case "select":
                    ((SelectionItemPattern)PatternFor(element, SelectionItemPattern.Pattern, action)).Select();
                    break;
                case "set_value":
                    ValuePattern valuePattern = (ValuePattern)PatternFor(element, ValuePattern.Pattern, action);
                    if (valuePattern.Current.IsReadOnly)
                    {
                        throw new HelperException("the element is read-only; its value cannot be set; type into another element or change it in the app");
                    }
                    valuePattern.SetValue(value);
                    break;
                case "focus":
                    element.SetFocus();
                    break;
                case "scroll_into_view":
                    ((ScrollItemPattern)PatternFor(element, ScrollItemPattern.Pattern, action)).ScrollIntoView();
                    break;
            }
        }

        // TryEnter counts one more worker for the app in counts, unless max are already running
        // in it.
        static bool TryEnter(Dictionary<int, int> counts, int max, int pid, out int running)
        {
            lock (actLock)
            {
                counts.TryGetValue(pid, out running);
                if (running >= max)
                {
                    return false;
                }
                counts[pid] = running + 1;
                return true;
            }
        }

        static void Leave(Dictionary<int, int> counts, int pid)
        {
            lock (actLock)
            {
                int n;
                if (counts.TryGetValue(pid, out n))
                {
                    if (n <= 1)
                    {
                        counts.Remove(pid);
                    }
                    else
                    {
                        counts[pid] = n - 1;
                    }
                }
            }
        }

        Dictionary<string, object> UiAct(Dictionary<string, object> req)
        {
            string action = Params.Str(req, "action");
            if (action == null || Array.IndexOf(actions, action) < 0)
            {
                throw new HelperException("action must be one of " + string.Join(", ", actions));
            }
            string value = Params.Str(req, "value");
            if (action == "set_value" && value == null)
            {
                throw new HelperException("set_value needs value");
            }
            AutomationElement element = Target(req);
            IntPtr hwnd = scopeWindow != IntPtr.Zero ? scopeWindow : TopWindowOrZero(element);
            IntPtr elementHwnd = ElementHwnd(element);
            bool belowPassword = HasPasswordAncestor(element);
            Dictionary<string, object> before = Node(element, 0);
            if (belowPassword)
            {
                MarkBelowPassword(before);
            }
            if (((List<object>)before["flags"]).Contains("disabled"))
            {
                throw new HelperException("the element is disabled; wait until it is enabled");
            }
            if (action == "focus" && hwnd != IntPtr.Zero && Native.IsWindow(hwnd))
            {
                Focus(hwnd);
            }

            int pid = 0;
            if (hwnd != IntPtr.Zero)
            {
                uint p;
                Native.GetWindowThreadProcessId(hwnd, out p);
                pid = (int)p;
            }
            if (pid == 0)
            {
                try { pid = (int)element.GetCurrentPropertyValue(AutomationElement.ProcessIdProperty); }
                catch (Exception) { }
            }
            int running;
            if (!TryEnter(actThreads, MaxActThreadsPerApp, pid, out running))
            {
                throw new HelperException(running + " earlier ui.act calls are still running in the app; wait for them or end its process with proc.kill");
            }

            bool known = hwnd != IntPtr.Zero && Native.IsWindow(hwnd);
            bool wasEnabled = known && Native.IsWindowEnabled(hwnd);
            Exception failure = null;
            Thread worker = new Thread(delegate()
            {
                try
                {
                    Perform(element, action, value);
                }
                catch (Exception e)
                {
                    failure = e;
                }
                finally
                {
                    Leave(actThreads, pid);
                }
            });
            worker.IsBackground = true;
            worker.SetApartmentState(ApartmentState.MTA);
            worker.Start();
            // The wait ends when the action returned, when the window is gone, or when the window
            // stopped taking input for a window it opened; the last counts as done.
            WaitUntil(delegate { return worker.Join(0) || (known && !Native.IsWindow(hwnd)) || (wasEnabled && !Native.IsWindowEnabled(hwnd)); }, ActWaitMs);
            bool joined = worker.Join(0);
            bool modalOpened = wasEnabled && known && Native.IsWindow(hwnd) && !Native.IsWindowEnabled(hwnd);
            bool returned = joined || modalOpened;
            if (joined && failure != null)
            {
                if (failure is HelperException)
                {
                    throw failure;
                }
                if (failure is ElementNotEnabledException)
                {
                    throw new HelperException("the element is disabled; wait until it is enabled");
                }
                if (failure is InvalidOperationException)
                {
                    throw new HelperException(action + " is not possible on the element in its present state: " + failure.Message);
                }
                if (failure is ElementNotAvailableException || failure is COMException
                    || failure is System.ComponentModel.Win32Exception || failure is UnauthorizedAccessException
                    || failure is TimeoutException)
                {
                    UiaHelper.Log("'ui.act' " + action + " ended with " + failure.GetType().Name + ": " + failure.Message);
                    // The element counts as gone when the window the action ran on, or the element's
                    // own window, stops existing within RefGoneWaitMs, or when reading the element
                    // again says it no longer exists. A failure the element and its windows outlive is
                    // reported for a retry.
                    bool windowGone = (hwnd != IntPtr.Zero && WaitUntil(delegate { return !Native.IsWindow(hwnd); }, RefGoneWaitMs))
                        || (elementHwnd != IntPtr.Zero && !Native.IsWindow(elementHwnd))
                        || ElementGone(element);
                    if (windowGone)
                    {
                        Dictionary<string, object> ended = new Dictionary<string, object>();
                        ended["node"] = before;
                        ended["gone"] = true;
                        return ended;
                    }
                    throw new HelperException("the element's app did not complete " + action + " (0x"
                        + Marshal.GetHRForException(failure).ToString("x8", CultureInfo.InvariantCulture)
                        + "); read the element again with ui.find and retry");
                }
                UiaHelper.Log("'ui.act' " + action + " failed: " + failure);
                throw new HelperException(action + " failed: " + failure.Message + "; see helper.log in the agent's uia folder");
            }

            Dictionary<string, object> r = new Dictionary<string, object>();
            Thread.Sleep(ActSettleMs);
            if (known && !Native.IsWindow(hwnd))
            {
                r["node"] = before;
                r["gone"] = true;
                return r;
            }
            if (elementHwnd != IntPtr.Zero && !Native.IsWindow(elementHwnd))
            {
                r["node"] = before;
                r["gone"] = true;
                return r;
            }
            if (hwnd != IntPtr.Zero && Native.IsWindow(hwnd) && !Responds(hwnd, ActRespondMs))
            {
                r["node"] = before;
                r["unresponsive"] = true;
                return r;
            }
            if (!returned)
            {
                // The pattern call is still running and the window answers messages.
                r["node"] = before;
                r["pending"] = true;
                return r;
            }
            try
            {
                Dictionary<string, object> node = Node(element.GetUpdatedCache(nodeCacheControl), 0);
                if (belowPassword)
                {
                    MarkBelowPassword(node);
                }
                r["node"] = node;
            }
            catch (ElementNotAvailableException)
            {
                r["node"] = before;
                r["gone"] = true;
            }
            catch (COMException)
            {
                r["node"] = before;
                r["gone"] = true;
            }
            catch (InvalidOperationException)
            {
                r["node"] = before;
                r["gone"] = true;
            }
            return r;
        }

        // The element's own window handle, or zero when the element has none or cannot be read.
        static IntPtr ElementHwnd(AutomationElement element)
        {
            try
            {
                object handle = element.GetCurrentPropertyValue(AutomationElement.NativeWindowHandleProperty);
                return handle is int && (int)handle != 0 ? new IntPtr((int)handle) : IntPtr.Zero;
            }
            catch (ElementNotAvailableException) { return IntPtr.Zero; }
            catch (COMException) { return IntPtr.Zero; }
            catch (InvalidOperationException) { return IntPtr.Zero; }
            catch (System.ComponentModel.Win32Exception) { return IntPtr.Zero; }
        }

        // True when reading the element again says it no longer exists or belongs to no process.
        // A read that fails for another reason (a busy or guarded element) is not gone.
        bool ElementGone(AutomationElement element)
        {
            try
            {
                AutomationElement fresh = element.GetUpdatedCache(nodeCacheControl);
                object pid = fresh.GetCurrentPropertyValue(AutomationElement.ProcessIdProperty);
                return !(pid is int) || (int)pid == 0;
            }
            catch (ElementNotAvailableException) { return true; }
            catch (COMException) { return false; }
            catch (InvalidOperationException) { return false; }
            catch (System.ComponentModel.Win32Exception) { return false; }
        }

        // ---- refs ----

        string RefFor(AutomationElement element)
        {
            string key = null;
            try
            {
                int[] id = element.GetRuntimeId();
                if (id != null && id.Length > 0)
                {
                    StringBuilder sb = new StringBuilder();
                    for (int i = 0; i < id.Length; i++)
                    {
                        sb.Append(id[i].ToString(CultureInfo.InvariantCulture)).Append('.');
                    }
                    key = sb.ToString();
                }
            }
            catch (ElementNotAvailableException) { }
            catch (InvalidOperationException) { }

            RefEntry entry;
            if (key != null && refsByKey.TryGetValue(key, out entry))
            {
                entry.Element = element;
                entry.Window = scopeWindow;
                entry.Used = ++clock;
                return "e" + entry.Number.ToString(CultureInfo.InvariantCulture);
            }
            entry = new RefEntry();
            entry.Number = nextRef++;
            entry.Key = key;
            entry.Element = element;
            entry.Window = scopeWindow;
            entry.Used = ++clock;
            refsByNumber[entry.Number] = entry;
            if (key != null)
            {
                refsByKey[key] = entry;
            }
            if (refsByNumber.Count > MaxRefs)
            {
                DropOldRefs();
            }
            return "e" + entry.Number.ToString(CultureInfo.InvariantCulture);
        }

        // Forgets the half of the refs that were used least recently.
        void DropOldRefs()
        {
            List<RefEntry> entries = new List<RefEntry>(refsByNumber.Values);
            entries.Sort(delegate(RefEntry a, RefEntry b) { return a.Used.CompareTo(b.Used); });
            for (int i = 0; i < entries.Count / 2; i++)
            {
                ForgetRef(entries[i]);
            }
        }

        void ForgetRef(RefEntry entry)
        {
            refsByNumber.Remove(entry.Number);
            RefEntry byKey;
            if (entry.Key != null && refsByKey.TryGetValue(entry.Key, out byKey) && byKey == entry)
            {
                refsByKey.Remove(entry.Key);
            }
        }

        static string GoneSentence(string reference)
        {
            return "element " + reference + " no longer exists; call ui.tree again";
        }

        // Returns the entry of a ref.
        RefEntry LookupRef(string reference)
        {
            int number;
            if (reference.Length < 2 || reference[0] != 'e'
                || !int.TryParse(reference.Substring(1), NumberStyles.None, CultureInfo.InvariantCulture, out number))
            {
                throw new HelperException("ref " + Json.Write(reference) + " is not a ref; refs look like e12 and come from ui.tree or ui.find");
            }
            RefEntry entry;
            if (!refsByNumber.TryGetValue(number, out entry))
            {
                throw new HelperException(GoneSentence(reference));
            }
            return entry;
        }

        // Returns the element of a ref with fresh cached properties.
        AutomationElement ResolveRef(string reference)
        {
            RefEntry entry = LookupRef(reference);
            string gone = GoneSentence(reference);
            scopeWindow = entry.Window;
            if (entry.Window != IntPtr.Zero && Native.IsWindow(entry.Window))
            {
                RequireResponding(entry.Window);
            }
            try
            {
                AutomationElement fresh = entry.Element.GetUpdatedCache(nodeCacheControl);
                int pid = (int)fresh.GetCurrentPropertyValue(AutomationElement.ProcessIdProperty);
                if (pid == 0)
                {
                    throw new ElementNotAvailableException();
                }
                entry.Element = fresh;
                entry.Used = ++clock;
                return fresh;
            }
            catch (ElementNotAvailableException)
            {
                ForgetRef(entry);
                throw new HelperException(gone);
            }
            catch (COMException)
            {
                ForgetRef(entry);
                throw new HelperException(gone);
            }
            catch (System.ComponentModel.Win32Exception)
            {
                // The ref is gone when its window stops existing within RefGoneWaitMs of the failed read.
                if (entry.Window == IntPtr.Zero || !WaitUntil(delegate { return !Native.IsWindow(entry.Window); }, RefGoneWaitMs))
                {
                    throw;
                }
                ForgetRef(entry);
                throw new HelperException(gone);
            }
        }

        // ---- nodes ----

        static string RoleName(ControlType type)
        {
            if (type == null)
            {
                return "Custom";
            }
            string name = type.ProgrammaticName;
            return name.StartsWith("ControlType.", StringComparison.Ordinal) ? name.Substring(12) : name;
        }

        static string Newlines(string text)
        {
            return text.IndexOf('\r') < 0 ? text : text.Replace("\r\n", "\n").Replace('\r', '\n');
        }

        static string Cut(string text, int max)
        {
            if (text.Length <= max)
            {
                return text;
            }
            int end = max;
            if (char.IsHighSurrogate(text[end - 1]))
            {
                end--;
            }
            return text.Substring(0, end) + "…";
        }

        // The cached value of a property, or null when the element does not have it or its
        // provider failed to read it.
        static object Cached(AutomationElement element, AutomationProperty property)
        {
            try
            {
                return element.GetCachedPropertyValue(property, true);
            }
            catch (InvalidOperationException)
            {
                return null;
            }
        }

        static string CachedValue(AutomationElement element)
        {
            return Cached(element, ValuePattern.ValueProperty) as string;
        }

        static bool CachedBool(AutomationElement element, AutomationProperty property)
        {
            object v = Cached(element, property);
            return v is bool && (bool)v;
        }

        // Whether the element is a password field, from its cached IsPassword. A read that fails
        // counts as a password field.
        static bool IsPasswordElement(AutomationElement element)
        {
            try
            {
                object v = element.GetCachedPropertyValue(AutomationElement.IsPasswordProperty, true);
                return v is bool && (bool)v;
            }
            catch (InvalidOperationException)
            {
                return true;
            }
        }

        // Whether one of the element's parents is a password field, read live. A parent that
        // cannot be read, for any of the reasons caught here, and a chain of more than
        // MaxWalkDepth parents count as a password field.
        static bool HasPasswordAncestor(AutomationElement element)
        {
            try
            {
                AutomationElement current = TreeWalker.RawViewWalker.GetParent(element);
                for (int i = 0; i < MaxWalkDepth; i++)
                {
                    if (current == null)
                    {
                        return false;
                    }
                    object v = current.GetCurrentPropertyValue(AutomationElement.IsPasswordProperty);
                    if (v is bool && (bool)v)
                    {
                        return true;
                    }
                    current = TreeWalker.RawViewWalker.GetParent(current);
                }
                return current != null;
            }
            catch (InvalidOperationException)
            {
                return true;
            }
            catch (ElementNotAvailableException)
            {
                return true;
            }
            catch (COMException)
            {
                return true;
            }
            catch (System.ComponentModel.Win32Exception)
            {
                return true;
            }
        }

        // Marks a node as lying below a password field: the password flag is set, the name is
        // emptied and the value is removed.
        static void MarkBelowPassword(Dictionary<string, object> node)
        {
            node.Remove("value");
            node["name"] = "";
            List<object> flags = (List<object>)node["flags"];
            if (!flags.Contains("password"))
            {
                flags.Add("password");
            }
        }

        // Builds the node object from the element's cached properties and gives the element a ref.
        Dictionary<string, object> Node(AutomationElement element, int depth)
        {
            Dictionary<string, object> n = new Dictionary<string, object>();
            n["ref"] = RefFor(element);
            NodeFields(n, element, depth);
            return n;
        }

        // Adds the node fields other than ref from the element's cached properties. A password
        // field has an empty name and no value.
        static void NodeFields(Dictionary<string, object> n, AutomationElement element, int depth)
        {
            bool password = IsPasswordElement(element);
            n["depth"] = depth;
            n["role"] = RoleName(element.GetCachedPropertyValue(AutomationElement.ControlTypeProperty) as ControlType);
            n["name"] = password ? "" : (element.GetCachedPropertyValue(AutomationElement.NameProperty) as string) ?? "";
            string value = password ? null : CachedValue(element);
            if (!string.IsNullOrEmpty(value))
            {
                n["value"] = Cut(Newlines(value), ValueCut);
            }
            string aid = element.GetCachedPropertyValue(AutomationElement.AutomationIdProperty) as string;
            if (!string.IsNullOrEmpty(aid))
            {
                n["aid"] = aid;
            }
            int x = 0, y = 0, w = 0, h = 0;
            object rectValue = element.GetCachedPropertyValue(AutomationElement.BoundingRectangleProperty);
            if (rectValue is Rect)
            {
                Rect rect = (Rect)rectValue;
                if (!rect.IsEmpty && !double.IsInfinity(rect.Width) && !double.IsInfinity(rect.Height)
                    && !double.IsNaN(rect.X) && !double.IsNaN(rect.Y))
                {
                    x = (int)Math.Round(rect.X);
                    y = (int)Math.Round(rect.Y);
                    w = (int)Math.Round(rect.Width);
                    h = (int)Math.Round(rect.Height);
                }
            }
            n["x"] = x;
            n["y"] = y;
            n["w"] = w;
            n["h"] = h;
            List<object> flags = new List<object>();
            if (CachedBool(element, AutomationElement.HasKeyboardFocusProperty)) { flags.Add("focused"); }
            object enabled = element.GetCachedPropertyValue(AutomationElement.IsEnabledProperty);
            if (enabled is bool && !(bool)enabled) { flags.Add("disabled"); }
            if (CachedBool(element, AutomationElement.IsOffscreenProperty)) { flags.Add("offscreen"); }
            if (CachedBool(element, SelectionItemPattern.IsSelectedProperty)) { flags.Add("selected"); }
            object toggle = Cached(element, TogglePattern.ToggleStateProperty);
            if (toggle is ToggleState && (ToggleState)toggle == ToggleState.On) { flags.Add("checked"); }
            object expand = Cached(element, ExpandCollapsePattern.ExpandCollapseStateProperty);
            if (expand is ExpandCollapseState)
            {
                ExpandCollapseState state = (ExpandCollapseState)expand;
                if (state == ExpandCollapseState.Expanded || state == ExpandCollapseState.PartiallyExpanded) { flags.Add("expanded"); }
                if (state == ExpandCollapseState.Collapsed) { flags.Add("collapsed"); }
            }
            if (password) { flags.Add("password"); }
            n["flags"] = flags;
        }

        // An element with a name, a value, keyboard focus support or a control type people act on.
        bool IsInteractive(AutomationElement element)
        {
            string name = element.GetCachedPropertyValue(AutomationElement.NameProperty) as string;
            if (!string.IsNullOrEmpty(name) || !string.IsNullOrEmpty(CachedValue(element)))
            {
                return true;
            }
            if (CachedBool(element, AutomationElement.IsKeyboardFocusableProperty)
                || CachedBool(element, AutomationElement.IsInvokePatternAvailableProperty))
            {
                return true;
            }
            ControlType type = element.GetCachedPropertyValue(AutomationElement.ControlTypeProperty) as ControlType;
            return type != null && interactiveTypes.Contains(type);
        }

        // ---- ui.tree ----

        sealed class TreeWalk
        {
            public TreeWalker Walker;
            public CacheRequest Cache;
            public bool All;
            public int Max;
            public int Depth;
            public List<object> Nodes = new List<object>();
            public bool Truncated;
        }

        Dictionary<string, object> UiTree(Dictionary<string, object> req)
        {
            string filter = Params.Str(req, "filter") ?? "interactive";
            if (filter != "interactive" && filter != "all")
            {
                throw new HelperException("filter must be interactive or all");
            }
            TreeWalk walk = new TreeWalk();
            walk.All = filter == "all";
            walk.Walker = walk.All ? TreeWalker.RawViewWalker : TreeWalker.ControlViewWalker;
            walk.Cache = walk.All ? nodeCacheRaw : nodeCacheControl;
            walk.Depth = Params.Int(req, "depth", DefaultTreeDepth);
            walk.Max = Params.Int(req, "max", DefaultTreeMax);
            if (walk.Depth < 0)
            {
                throw new HelperException("depth must be 0 or more");
            }
            if (walk.Depth > MaxWalkDepth)
            {
                throw new HelperException("depth must be " + MaxWalkDepth + " or less; read deeper parts with root");
            }
            if (walk.Max < 1)
            {
                throw new HelperException("max must be 1 or more");
            }
            if (walk.Max > TreeMaxCap)
            {
                walk.Max = TreeMaxCap;
            }

            AutomationElement root;
            IntPtr hwnd;
            string rootRef = Params.Str(req, "root");
            if (rootRef != null)
            {
                root = ResolveRef(rootRef).GetUpdatedCache(walk.Cache);
                if (HasPasswordAncestor(root))
                {
                    throw new HelperException(PasswordSentence);
                }
                hwnd = TopWindow(root);
            }
            else
            {
                hwnd = ResolveWindow(Params.Str(req, "window"));
                root = WindowElement(hwnd, walk.Cache);
            }
            scopeWindow = hwnd;

            walk.Nodes.Add(Node(root, 0));
            if (!IsPasswordElement(root))
            {
                WalkChildren(walk, root, 0, 1);
            }

            Dictionary<string, object> r = new Dictionary<string, object>();
            r["window"] = WindowObjectOrNull(hwnd);
            r["nodes"] = walk.Nodes;
            r["truncated"] = walk.Truncated;
            return r;
        }

        // Adds the subtree below parent. level is the parent's distance from the root; nodes of the
        // next level get nodeDepth, which counts only the ancestors that are in the answer. The walk
        // is marked truncated when a listed element does not fit in max, when the time for the
        // request is used up and when an element disappears under it.
        void WalkChildren(TreeWalk walk, AutomationElement parent, int level, int nodeDepth)
        {
            if (level >= walk.Depth)
            {
                return;
            }
            AutomationElement child;
            try
            {
                child = walk.Walker.GetFirstChild(parent, walk.Cache);
            }
            catch (ElementNotAvailableException)
            {
                walk.Truncated = true;
                return;
            }
            while (child != null && !walk.Truncated)
            {
                if (OutOfTime())
                {
                    walk.Truncated = true;
                    return;
                }
                try
                {
                    bool listed = walk.All || IsInteractive(child);
                    if (listed && walk.Nodes.Count >= walk.Max)
                    {
                        walk.Truncated = true;
                        return;
                    }
                    if (listed)
                    {
                        walk.Nodes.Add(Node(child, nodeDepth));
                    }
                    // The children of a password field are not listed.
                    if (!IsPasswordElement(child))
                    {
                        WalkChildren(walk, child, level + 1, listed ? nodeDepth + 1 : nodeDepth);
                    }
                    if (walk.Truncated)
                    {
                        return;
                    }
                    child = walk.Walker.GetNextSibling(child, walk.Cache);
                }
                catch (ElementNotAvailableException)
                {
                    walk.Truncated = true;
                    return;
                }
            }
        }

        // ---- selectors ----

        static Selector ReadSelector(Dictionary<string, object> req)
        {
            Selector s = new Selector();
            s.Window = Params.Str(req, "window");
            s.Role = Params.Str(req, "role");
            s.Name = Params.Str(req, "name");
            s.NameContains = Params.Str(req, "nameContains");
            s.AutomationId = Params.Str(req, "automationId");
            s.Index = Params.Int(req, "index", -1);
            if (Params.Has(req, "index") && s.Index < 0)
            {
                throw new HelperException("index must be 0 or more");
            }
            return s;
        }

        bool OutOfTime()
        {
            return watch.ElapsedMilliseconds > budgetMs;
        }

        // Why a walk ended before it had seen every element.
        enum Stop { None, Time, Depth, Changed }

        sealed class Search
        {
            public Selector Selector;
            public ControlType Type;
            public int Need;
            public List<AutomationElement> Found = new List<AutomationElement>();
            public Stop Stopped = Stop.None;
        }

        // Walks the control view of the selector's window in tree order and collects the matching
        // elements until `need` are found or the time for the request is used up.
        Search Matches(Selector selector, int need)
        {
            if (!selector.HasCriteria)
            {
                throw new HelperException("pass ref or at least one of role, name, nameContains, automationId");
            }
            Search search = new Search();
            search.Selector = selector;
            search.Need = need;
            if (selector.Role != null && !rolesByName.TryGetValue(selector.Role, out search.Type))
            {
                List<string> names = new List<string>(rolesByName.Keys);
                names.Sort(StringComparer.Ordinal);
                throw new HelperException("unknown role " + Json.Write(selector.Role) + "; use one of " + string.Join(", ", names.ToArray()));
            }
            scopeWindow = ResolveWindow(selector.Window);
            AutomationElement root = WindowElement(scopeWindow, matchCache);
            if (IsMatch(search, root))
            {
                search.Found.Add(root);
            }
            if (search.Found.Count < need)
            {
                SearchChildren(search, root, 1);
            }
            return search;
        }

        static bool IsMatch(Search search, AutomationElement element)
        {
            Selector selector = search.Selector;
            if (search.Type != null && search.Type != element.GetCachedPropertyValue(AutomationElement.ControlTypeProperty) as ControlType)
            {
                return false;
            }
            if (selector.Name != null || selector.NameContains != null)
            {
                string name = (element.GetCachedPropertyValue(AutomationElement.NameProperty) as string) ?? "";
                if (selector.Name != null && !string.Equals(name, selector.Name, StringComparison.Ordinal))
                {
                    return false;
                }
                if (selector.NameContains != null && name.IndexOf(selector.NameContains, StringComparison.OrdinalIgnoreCase) < 0)
                {
                    return false;
                }
            }
            if (selector.AutomationId != null)
            {
                string aid = (element.GetCachedPropertyValue(AutomationElement.AutomationIdProperty) as string) ?? "";
                if (!string.Equals(aid, selector.AutomationId, StringComparison.Ordinal))
                {
                    return false;
                }
            }
            return true;
        }

        // Checks the children of parent, which are `level` levels below the window.
        void SearchChildren(Search search, AutomationElement parent, int level)
        {
            AutomationElement child;
            try
            {
                child = TreeWalker.ControlViewWalker.GetFirstChild(parent, matchCache);
            }
            catch (ElementNotAvailableException)
            {
                search.Stopped = Stop.Changed;
                return;
            }
            if (child != null && level > MaxWalkDepth)
            {
                search.Stopped = Stop.Depth;
                return;
            }
            while (child != null)
            {
                if (OutOfTime())
                {
                    search.Stopped = Stop.Time;
                    return;
                }
                try
                {
                    if (IsMatch(search, child))
                    {
                        search.Found.Add(child);
                    }
                    // A password field is a match but its children are not searched.
                    if (search.Found.Count < search.Need && !IsPasswordElement(child))
                    {
                        SearchChildren(search, child, level + 1);
                    }
                    if (search.Stopped != Stop.None || search.Found.Count >= search.Need)
                    {
                        return;
                    }
                    child = TreeWalker.ControlViewWalker.GetNextSibling(child, matchCache);
                }
                catch (ElementNotAvailableException)
                {
                    search.Stopped = Stop.Changed;
                    return;
                }
            }
        }

        // The error for a search that ended before it found what was asked for.
        string SearchStopped(Search search)
        {
            string what = "the search for " + search.Selector.ToJson();
            switch (search.Stopped)
            {
                case Stop.Depth:
                    return what + " stopped " + MaxWalkDepth + " levels below the window; read the deeper part with ui.tree and root, then use a ref";
                case Stop.Changed:
                    return what + " met an element that disappeared; call the operation again";
                default:
                    return what + " did not finish within " + (budgetMs / 1000) + " s; read the window in parts with ui.tree and root, then use a ref";
            }
        }

        // Returns the element named by "ref" or by the selector fields, with fresh cached properties.
        AutomationElement Target(Dictionary<string, object> req)
        {
            string reference = Params.Str(req, "ref");
            if (reference != null)
            {
                return ResolveRef(reference);
            }
            Selector selector = ReadSelector(req);
            int index = selector.Index < 0 ? 0 : selector.Index;
            Search search = Matches(selector, index + 1);
            if (index >= search.Found.Count)
            {
                if (search.Stopped != Stop.None)
                {
                    throw new HelperException(SearchStopped(search));
                }
                throw new HelperException("no element matches " + selector.ToJson() + "; call ui.tree to see what exists");
            }
            try
            {
                return search.Found[index].GetUpdatedCache(nodeCacheControl);
            }
            catch (ElementNotAvailableException)
            {
                throw new HelperException("no element matches " + selector.ToJson() + "; call ui.tree to see what exists");
            }
        }

        // ---- ui.find ----

        Dictionary<string, object> UiFind(Dictionary<string, object> req)
        {
            Selector selector = ReadSelector(req);
            int limit = Params.Int(req, "limit", DefaultFindLimit);
            if (limit < 1)
            {
                throw new HelperException("limit must be 1 or more");
            }
            if (limit > TreeMaxCap)
            {
                limit = TreeMaxCap;
            }
            int first = selector.Index < 0 ? 0 : selector.Index;
            Search search = Matches(selector, selector.Index < 0 ? limit : first + 1);
            if (search.Stopped != Stop.None && search.Found.Count <= first)
            {
                throw new HelperException(SearchStopped(search));
            }
            List<object> nodes = new List<object>();
            bool vanished = false;
            for (int i = first; i < search.Found.Count; i++)
            {
                try
                {
                    nodes.Add(Node(search.Found[i].GetUpdatedCache(nodeCacheControl), 0));
                }
                catch (ElementNotAvailableException)
                {
                    vanished = true;
                }
            }
            Dictionary<string, object> r = new Dictionary<string, object>();
            r["nodes"] = nodes;
            if (search.Stopped != Stop.None || vanished)
            {
                r["truncated"] = true;
            }
            return r;
        }

        // ---- ui.text ----

        Dictionary<string, object> UiText(Dictionary<string, object> req)
        {
            string mode = Params.Str(req, "mode") ?? "auto";
            if (mode != "auto" && mode != "pattern" && mode != "descendants")
            {
                throw new HelperException("mode must be auto, pattern or descendants");
            }
            int offset = Params.Int(req, "offset", 0);
            int length = Params.Int(req, "length", TextCap);
            if (offset < 0)
            {
                throw new HelperException("offset must be 0 or more");
            }
            if (length < 0)
            {
                throw new HelperException("length must be 0 or more");
            }
            if (length > TextCap)
            {
                length = TextCap;
            }
            AutomationElement element = Target(req);
            if (IsPasswordElement(element) || HasPasswordAncestor(element))
            {
                throw new HelperException(PasswordSentence);
            }

            string text = null;
            string source = null;
            if (mode != "descendants")
            {
                object pattern;
                if (element.TryGetCurrentPattern(TextPattern.Pattern, out pattern))
                {
                    text = ((TextPattern)pattern).DocumentRange.GetText(-1) ?? "";
                    source = "text";
                }
                else if (mode == "pattern")
                {
                    throw new HelperException("the element has no text pattern; use mode auto or descendants");
                }
            }
            // An empty value counts as the text of an edit or a document only; other elements go on to their descendants.
            string value = null;
            if (text == null && mode == "auto")
            {
                value = CachedValue(element);
                ControlType type = element.GetCachedPropertyValue(AutomationElement.ControlTypeProperty) as ControlType;
                if (value != null && (value.Length > 0 || type == ControlType.Edit || type == ControlType.Document))
                {
                    text = value;
                    source = "value";
                }
            }
            if (text == null)
            {
                string joined = DescendantNames(element);
                if (joined.Length > 0 || mode == "descendants")
                {
                    text = joined;
                    source = "descendants";
                }
            }
            if (text == null && value != null)
            {
                text = value;
                source = "value";
            }
            if (text == null)
            {
                text = (element.GetCachedPropertyValue(AutomationElement.NameProperty) as string) ?? "";
                source = "name";
            }

            text = Newlines(text);
            int total = text.Length;
            int start = Math.Min(offset, total);
            int end = (int)Math.Min((long)start + length, total);
            if (start > 0 && start < total && char.IsLowSurrogate(text[start]) && char.IsHighSurrogate(text[start - 1]))
            {
                start--;
            }
            if (end > start && end < total && char.IsHighSurrogate(text[end - 1]) && char.IsLowSurrogate(text[end]))
            {
                end++;
            }
            Dictionary<string, object> r = new Dictionary<string, object>();
            r["text"] = length == 0 ? "" : text.Substring(start, end - start);
            r["total"] = total;
            r["source"] = source;
            return r;
        }

        // The text, list item, edit and document elements below the element, one per line: the value
        // of an edit or document that has one, the name otherwise. Password fields and everything
        // below them are left out.
        string DescendantNames(AutomationElement element)
        {
            StringBuilder sb = new StringBuilder();
            switch (CollectText(element, sb, 1))
            {
                case Stop.Time:
                    throw new HelperException("the text below the element was not read within " + (budgetMs / 1000)
                        + " s; read a smaller element: list its parts with ui.tree and root");
                case Stop.Depth:
                    throw new HelperException("the text below the element lies more than " + MaxWalkDepth
                        + " levels deep; read a smaller element: list its parts with ui.tree and root");
                case Stop.Changed:
                    throw new HelperException("an element disappeared while the text was read; call ui.text again");
            }
            return sb.ToString();
        }

        // Appends the text of the children of parent, which are `level` levels below the element.
        Stop CollectText(AutomationElement parent, StringBuilder sb, int level)
        {
            AutomationElement child;
            try
            {
                child = TreeWalker.ControlViewWalker.GetFirstChild(parent, textCache);
            }
            catch (ElementNotAvailableException)
            {
                return Stop.Changed;
            }
            if (child != null && level > MaxWalkDepth)
            {
                return Stop.Depth;
            }
            while (child != null)
            {
                if (OutOfTime())
                {
                    return Stop.Time;
                }
                try
                {
                    if (!IsPasswordElement(child))
                    {
                        ControlType type = child.GetCachedPropertyValue(AutomationElement.ControlTypeProperty) as ControlType;
                        if (type == ControlType.Text || type == ControlType.ListItem || type == ControlType.Edit || type == ControlType.Document)
                        {
                            string line = child.GetCachedPropertyValue(AutomationElement.NameProperty) as string;
                            if (type == ControlType.Edit || type == ControlType.Document)
                            {
                                string value = CachedValue(child);
                                if (!string.IsNullOrEmpty(value))
                                {
                                    line = value;
                                }
                            }
                            if (!string.IsNullOrEmpty(line))
                            {
                                if (sb.Length > 0)
                                {
                                    sb.Append('\n');
                                }
                                sb.Append(line);
                            }
                        }
                        Stop stopped = CollectText(child, sb, level + 1);
                        if (stopped != Stop.None)
                        {
                            return stopped;
                        }
                    }
                    child = TreeWalker.ControlViewWalker.GetNextSibling(child, textCache);
                }
                catch (ElementNotAvailableException)
                {
                    return Stop.Changed;
                }
            }
            return Stop.None;
        }

        // ---- ui.rect ----

        Dictionary<string, object> UiRect(Dictionary<string, object> req)
        {
            AutomationElement element = Target(req);
            if (Params.Bool(req, "scroll", false))
            {
                object pattern;
                if (element.TryGetCurrentPattern(ScrollItemPattern.Pattern, out pattern))
                {
                    try
                    {
                        ((ScrollItemPattern)pattern).ScrollIntoView();
                        Thread.Sleep(150);
                    }
                    catch (InvalidOperationException) { }
                    element = element.GetUpdatedCache(nodeCacheControl);
                }
            }
            Dictionary<string, object> node = Node(element, 0);
            if (HasPasswordAncestor(element))
            {
                MarkBelowPassword(node);
            }
            int x = (int)node["x"], y = (int)node["y"], w = (int)node["w"], h = (int)node["h"];
            int cx = x + w / 2, cy = y + h / 2;
            List<object> flags = (List<object>)node["flags"];
            string blocked = null;
            if (w <= 0 || h <= 0)
            {
                blocked = "the element has no rectangle on screen";
            }
            else if (flags.Contains("offscreen"))
            {
                blocked = "the element is scrolled out of view or hidden; pass scroll: true or scroll it into view";
            }
            else if (flags.Contains("disabled"))
            {
                blocked = "the element is disabled";
            }
            else
            {
                int left = Native.GetSystemMetrics(76), top = Native.GetSystemMetrics(77);
                int right = left + Native.GetSystemMetrics(78), bottom = top + Native.GetSystemMetrics(79);
                if (cx < left || cy < top || cx >= right || cy >= bottom)
                {
                    blocked = "the centre of the element is outside the screen; move its window with win.action";
                }
                else
                {
                    IntPtr own = TopWindow(element);
                    Native.POINT point = new Native.POINT();
                    point.X = cx;
                    point.Y = cy;
                    IntPtr hit = Native.WindowFromPoint(point);
                    IntPtr hitTop = hit == IntPtr.Zero ? IntPtr.Zero : Native.GetAncestor(hit, Native.GA_ROOT);
                    if (own != IntPtr.Zero && hitTop != own)
                    {
                        blocked = "window " + HwndId(hitTop) + " " + Json.Write(WindowTitle(hitTop))
                            + " covers the centre of the element; focus the element's window with win.action";
                    }
                }
            }
            Dictionary<string, object> r = new Dictionary<string, object>();
            r["node"] = node;
            r["cx"] = cx;
            r["cy"] = cy;
            r["clickable"] = blocked == null;
            if (blocked != null)
            {
                r["blocked"] = blocked;
            }
            return r;
        }

        // ---- ui.focused ----

        Dictionary<string, object> UiFocused()
        {
            AutomationElement element;
            try
            {
                using (nodeCacheControl.Activate())
                {
                    element = AutomationElement.FocusedElement;
                }
            }
            catch (ElementNotAvailableException)
            {
                element = null;
            }
            if (element == null)
            {
                throw new HelperException("no element has the keyboard focus; click a window or use win.action focus");
            }
            scopeWindow = TopWindow(element);
            Dictionary<string, object> node = Node(element, 0);
            if (HasPasswordAncestor(element))
            {
                MarkBelowPassword(node);
            }
            Dictionary<string, object> r = new Dictionary<string, object>();
            r["node"] = node;
            r["window"] = WindowObjectOrNull(scopeWindow);
            return r;
        }

        // ---- ui.at ----

        const int DefaultAtBudgetMs = 250;
        const int MinAtBudgetMs = 50;
        const int MaxAtBudgetMs = 2000;
        const int MaxAtThreadsPerApp = 8;
        const int AtStackBytes = 16 * 1024 * 1024;
        static readonly Dictionary<int, int> atThreads = new Dictionary<int, int>();

        enum AtMode { Point, Ref, Focused }

        // The element a ui.at worker found.
        sealed class AtLocated
        {
            public AutomationElement Element;
            public Dictionary<string, object> Node;
            public Dictionary<string, object> Window;
            public bool HasAutomationId;
            public bool HasName;
        }

        // The selector counts of a finished walk; a field is null when the walk did not meet the element.
        sealed class AtCounts
        {
            public Dictionary<string, object> ByAutomationId;
            public Dictionary<string, object> ByName;
        }

        // What one ui.at worker reports. The worker assigns each field at most once; the request
        // thread reads them when the worker ended or the time for the request is used up.
        sealed class AtAnswer
        {
            public volatile AtLocated Located;
            public volatile AtCounts Counts;
            public volatile bool Nothing;
            public volatile bool Gone;
            public volatile Exception Failure;
        }

        // The walk that counts the elements of a window that match the found element's
        // role and automation id, and its role and name.
        sealed class AtCount
        {
            public CacheRequest Cache;
            public Stopwatch Spent;
            public int BudgetMs;
            public ControlType Type;
            public int[] Target;
            public string AutomationId;
            public string Name;
            public int MatchesAutomationId, MatchesName;
            public int IndexAutomationId = -1, IndexName = -1;
            public bool Stopped;

            public void Visit(AutomationElement element)
            {
                if (Type != element.GetCachedPropertyValue(AutomationElement.ControlTypeProperty) as ControlType)
                {
                    return;
                }
                bool aid = AutomationId != null
                    && string.Equals((element.GetCachedPropertyValue(AutomationElement.AutomationIdProperty) as string) ?? "", AutomationId, StringComparison.Ordinal);
                bool name = Name != null
                    && string.Equals((element.GetCachedPropertyValue(AutomationElement.NameProperty) as string) ?? "", Name, StringComparison.Ordinal);
                if (!aid && !name)
                {
                    return;
                }
                bool target = ((aid && IndexAutomationId < 0) || (name && IndexName < 0)) && IsTarget(element);
                if (aid)
                {
                    if (target && IndexAutomationId < 0) { IndexAutomationId = MatchesAutomationId; }
                    MatchesAutomationId++;
                }
                if (name)
                {
                    if (target && IndexName < 0) { IndexName = MatchesName; }
                    MatchesName++;
                }
            }

            bool IsTarget(AutomationElement element)
            {
                int[] id = element.GetRuntimeId();
                if (id == null || id.Length != Target.Length)
                {
                    return false;
                }
                for (int i = 0; i < id.Length; i++)
                {
                    if (id[i] != Target[i])
                    {
                        return false;
                    }
                }
                return true;
            }

            public static Dictionary<string, object> Result(int matches, int index)
            {
                if (index < 0)
                {
                    return null;
                }
                Dictionary<string, object> d = new Dictionary<string, object>();
                d["matches"] = matches;
                d["index"] = index;
                return d;
            }
        }

        static int CachedHandle(AutomationElement element)
        {
            object v = Cached(element, AutomationElement.NativeWindowHandleProperty);
            return v is int ? (int)v : 0;
        }

        Dictionary<string, object> UiAt(Dictionary<string, object> req)
        {
            bool hasX = Params.Has(req, "x"), hasY = Params.Has(req, "y");
            string reference = Params.Str(req, "ref");
            bool focused = Params.Bool(req, "focused", false);
            if ((hasX || hasY ? 1 : 0) + (reference != null ? 1 : 0) + (focused ? 1 : 0) != 1 || hasX != hasY)
            {
                throw new HelperException("pass x and y, ref, or focused: true");
            }
            int budget = Math.Max(MinAtBudgetMs, Math.Min(MaxAtBudgetMs, Params.Int(req, "budgetMs", DefaultAtBudgetMs)));
            Stopwatch spent = Stopwatch.StartNew();
            AtMode mode = hasX ? AtMode.Point : focused ? AtMode.Focused : AtMode.Ref;
            int x = Params.Int(req, "x", 0), y = Params.Int(req, "y", 0);
            string nothing = mode == AtMode.Point
                ? "no element at (" + x.ToString(CultureInfo.InvariantCulture) + ", " + y.ToString(CultureInfo.InvariantCulture) + "); take a screenshot to see what is there"
                : "no element has the keyboard focus; click the field first";
            string late = (mode == AtMode.Point ? "no element at (" + x.ToString(CultureInfo.InvariantCulture) + ", " + y.ToString(CultureInfo.InvariantCulture) + ")"
                : mode == AtMode.Focused ? "the focused element was not read" : "element " + reference + " was not read")
                + ": the app did not answer within " + budget.ToString(CultureInfo.InvariantCulture) + " ms; retry";

            RefEntry entry = null;
            IntPtr top;
            if (mode == AtMode.Point)
            {
                int left = Native.GetSystemMetrics(76), topEdge = Native.GetSystemMetrics(77);
                if (x < left || y < topEdge || x >= left + Native.GetSystemMetrics(78) || y >= topEdge + Native.GetSystemMetrics(79))
                {
                    throw new HelperException(nothing);
                }
                Native.POINT point = new Native.POINT();
                point.X = x;
                point.Y = y;
                IntPtr hit = Native.WindowFromPoint(point);
                if (hit == IntPtr.Zero)
                {
                    throw new HelperException(nothing);
                }
                top = Native.GetAncestor(hit, Native.GA_ROOT);
            }
            else if (mode == AtMode.Ref)
            {
                entry = LookupRef(reference);
                top = entry.Window;
            }
            else
            {
                top = Native.ForegroundWindow();
            }
            if (top != IntPtr.Zero && (Native.IsHungAppWindow(top) || IsGhostOfHungWindow(top)))
            {
                throw new HelperException(late);
            }
            int pid = 0;
            if (top != IntPtr.Zero)
            {
                uint p;
                Native.GetWindowThreadProcessId(top, out p);
                pid = (int)p;
            }
            int running;
            if (!TryEnter(atThreads, MaxAtThreadsPerApp, pid, out running))
            {
                throw new HelperException(late);
            }

            AtAnswer answer = new AtAnswer();
            AutomationElement known = entry != null ? entry.Element : null;
            IntPtr refWindow = entry != null ? entry.Window : IntPtr.Zero;
            Thread worker = new Thread(delegate()
            {
                try
                {
                    AtWork(answer, mode, x, y, reference, known, refWindow, spent, budget);
                }
                catch (Exception e)
                {
                    answer.Failure = e;
                }
                finally
                {
                    Leave(atThreads, pid);
                }
            }, AtStackBytes);
            worker.IsBackground = true;
            worker.SetApartmentState(ApartmentState.MTA);
            worker.Start();
            worker.Join((int)Math.Max(0, budget - spent.ElapsedMilliseconds));

            AtLocated located = answer.Located;
            if (located == null)
            {
                if (answer.Gone)
                {
                    ForgetRef(entry);
                    throw new HelperException(GoneSentence(reference));
                }
                if (answer.Nothing)
                {
                    throw new HelperException(nothing);
                }
                Exception failure = answer.Failure;
                if (failure != null)
                {
                    throw new InvalidOperationException(failure.Message, failure);
                }
                throw new HelperException(late);
            }
            AtCounts counts = answer.Counts;
            if (entry != null)
            {
                entry.Element = located.Element;
                entry.Used = ++clock;
            }
            Dictionary<string, object> r = new Dictionary<string, object>();
            r["node"] = located.Node;
            r["window"] = located.Window;
            if (located.HasAutomationId)
            {
                r["byAutomationId"] = counts == null ? null : counts.ByAutomationId;
            }
            if (located.HasName)
            {
                r["byName"] = counts == null ? null : counts.ByName;
            }
            return r;
        }

        // Runs on a ui.at worker thread and uses no state of the session. Finds the element at
        // the point, with the focus or of the ref, then counts the selector matches in its
        // window until budget ms of spent have passed. For a point or the focus, an element
        // below a password field is replaced by the outermost password field above it, and the
        // result by its nearest ancestor in the control view. refWindow is the window the ref
        // was taken in; the window of a ref whose element and parents show no window handle is
        // TopWindow of the element, else refWindow while it exists. The counts are left out
        // when the window's title, given as a selector's window, names another window.
        static void AtWork(AtAnswer answer, AtMode mode, int x, int y, string reference, AutomationElement known, IntPtr refWindow, Stopwatch spent, int budget)
        {
            try { Native.SetThreadDpiAwarenessContext(new IntPtr(-4)); }
            catch (EntryPointNotFoundException) { }
            CacheRequest raw = NodeCache(Automation.RawViewCondition);
            raw.Add(AutomationElement.NativeWindowHandleProperty);
            raw.Add(AutomationElement.ProcessIdProperty);
            CacheRequest control = NodeCache(Automation.ControlViewCondition);
            control.Add(AutomationElement.NativeWindowHandleProperty);
            CacheRequest up = new CacheRequest();
            up.TreeFilter = Automation.RawViewCondition;
            up.Add(AutomationElement.IsPasswordProperty);
            up.Add(AutomationElement.NativeWindowHandleProperty);

            AutomationElement element;
            int handle;
            AutomationElement outer = null;
            bool unreadable = false;
            try
            {
                if (mode == AtMode.Ref)
                {
                    element = known.GetUpdatedCache(raw);
                    object owner = Cached(element, AutomationElement.ProcessIdProperty);
                    if (!(owner is int) || (int)owner == 0)
                    {
                        answer.Gone = true;
                        return;
                    }
                }
                else
                {
                    using (raw.Activate())
                    {
                        element = mode == AtMode.Point ? AutomationElement.FromPoint(new Point(x, y)) : AutomationElement.FocusedElement;
                    }
                    if (element == null)
                    {
                        answer.Nothing = true;
                        return;
                    }
                }
                handle = CachedHandle(element);
                try
                {
                    AutomationElement current = TreeWalker.RawViewWalker.GetParent(element, up);
                    for (int i = 0; i < MaxWalkDepth && current != null; i++)
                    {
                        if (IsPasswordElement(current))
                        {
                            outer = current;
                        }
                        if (handle == 0)
                        {
                            handle = CachedHandle(current);
                        }
                        current = TreeWalker.RawViewWalker.GetParent(current, up);
                    }
                    unreadable = current != null;
                }
                catch (InvalidOperationException) { unreadable = true; }
                catch (COMException) { unreadable = true; }
                catch (System.ComponentModel.Win32Exception) { unreadable = true; }
                if (mode != AtMode.Ref)
                {
                    element = TreeWalker.ControlViewWalker.Normalize(outer ?? element, control);
                    if (element == null)
                    {
                        answer.Nothing = true;
                        return;
                    }
                }
            }
            catch (ElementNotAvailableException)
            {
                if (mode == AtMode.Ref) { answer.Gone = true; } else { answer.Nothing = true; }
                return;
            }
            catch (COMException)
            {
                if (mode == AtMode.Ref) { answer.Gone = true; } else { answer.Nothing = true; }
                return;
            }
            catch (System.ComponentModel.Win32Exception)
            {
                if (mode != AtMode.Ref)
                {
                    answer.Nothing = true;
                    return;
                }
                // The ref is gone when the window it was taken in stops existing within the time left.
                int left = (int)Math.Max(0, budget - spent.ElapsedMilliseconds);
                if (refWindow != IntPtr.Zero && WaitUntil(delegate { return !Native.IsWindow(refWindow); }, Math.Min(RefGoneWaitMs, left)))
                {
                    answer.Gone = true;
                    return;
                }
                throw;
            }
            catch (UnauthorizedAccessException)
            {
                if (mode == AtMode.Ref) { throw; }
                answer.Nothing = true;
                return;
            }

            IntPtr desktop = Native.GetDesktopWindow();
            IntPtr top = IntPtr.Zero;
            if (handle != 0)
            {
                top = Native.GetAncestor(new IntPtr(handle), Native.GA_ROOT);
                if (top == IntPtr.Zero)
                {
                    top = new IntPtr(handle);
                }
            }
            else if (mode == AtMode.Ref)
            {
                top = TopWindowOrZero(element);
                if (top == IntPtr.Zero && refWindow != IntPtr.Zero && Native.IsWindow(refWindow))
                {
                    top = refWindow;
                }
            }
            if (top == IntPtr.Zero || top == desktop || (long)CachedHandle(element) == desktop.ToInt64())
            {
                if (mode == AtMode.Ref) { answer.Gone = true; } else { answer.Nothing = true; }
                return;
            }

            AtLocated located = new AtLocated();
            located.Element = element;
            located.Node = new Dictionary<string, object>();
            if (mode == AtMode.Ref)
            {
                located.Node["ref"] = reference;
            }
            NodeFields(located.Node, element, 0);
            if (unreadable || (mode == AtMode.Ref && outer != null))
            {
                MarkBelowPassword(located.Node);
            }
            located.Window = new Dictionary<string, object>();
            located.Window["id"] = HwndId(top);
            located.Window["title"] = WindowTitle(top);
            string name = (string)located.Node["name"];
            object aidValue;
            string aid = located.Node.TryGetValue("aid", out aidValue) ? (string)aidValue : "";
            bool password = ((List<object>)located.Node["flags"]).Contains("password");
            located.HasAutomationId = aid.Length > 0;
            located.HasName = name.Length > 0 && !password;
            answer.Located = located;
            if (!located.HasAutomationId && !located.HasName)
            {
                return;
            }
            if (!TitleResolvesTo((string)located.Window["title"], top))
            {
                return;
            }

            try
            {
                AtCount count = new AtCount();
                count.Spent = spent;
                count.BudgetMs = budget;
                count.Type = element.GetCachedPropertyValue(AutomationElement.ControlTypeProperty) as ControlType;
                count.Target = element.GetRuntimeId();
                count.AutomationId = located.HasAutomationId ? aid : null;
                count.Name = located.HasName ? name : null;
                if (count.Type == null || count.Target == null || count.Target.Length == 0)
                {
                    answer.Counts = new AtCounts();
                    return;
                }
                count.Cache = new CacheRequest();
                count.Cache.TreeFilter = Automation.ControlViewCondition;
                count.Cache.Add(AutomationElement.NameProperty);
                count.Cache.Add(AutomationElement.ControlTypeProperty);
                count.Cache.Add(AutomationElement.AutomationIdProperty);
                count.Cache.Add(AutomationElement.IsPasswordProperty);
                AutomationElement root;
                using (count.Cache.Activate())
                {
                    root = AutomationElement.FromHandle(top);
                }
                count.Visit(root);
                CountChildren(count, root, 1);
                if (!count.Stopped)
                {
                    AtCounts counts = new AtCounts();
                    counts.ByAutomationId = AtCount.Result(count.MatchesAutomationId, count.IndexAutomationId);
                    counts.ByName = AtCount.Result(count.MatchesName, count.IndexName);
                    answer.Counts = counts;
                }
            }
            catch (ElementNotAvailableException) { }
            catch (InvalidOperationException) { }
            catch (COMException) { }
            catch (System.ComponentModel.Win32Exception) { }
        }

        // Visits the children of parent, which are `level` levels below the window, in the order
        // SearchChildren visits them. The walk stops when its time is used up and MaxWalkDepth
        // levels below the window.
        static void CountChildren(AtCount count, AutomationElement parent, int level)
        {
            AutomationElement child = TreeWalker.ControlViewWalker.GetFirstChild(parent, count.Cache);
            if (child != null && level > MaxWalkDepth)
            {
                count.Stopped = true;
                return;
            }
            while (child != null)
            {
                if (count.Spent.ElapsedMilliseconds > count.BudgetMs)
                {
                    count.Stopped = true;
                    return;
                }
                count.Visit(child);
                if (!IsPasswordElement(child))
                {
                    CountChildren(count, child, level + 1);
                    if (count.Stopped)
                    {
                        return;
                    }
                }
                child = TreeWalker.ControlViewWalker.GetNextSibling(child, count.Cache);
            }
        }
    }
}
