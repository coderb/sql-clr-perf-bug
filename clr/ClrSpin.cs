using System;
using System.Data.SqlTypes;
using Microsoft.SqlServer.Server;

namespace ClrSpin {
    // Trivial scalar functions: each does a few character or integer comparisons, so any cost per call
    // beyond that is the engine's cost of calling into the CLR. The two parsers at the end do a real
    // function's work, taken as a string and as a SqlChars.
    public static class Functions {
        // The shape of a real function that showed the contention: two strings in, a nullable bool out.
        [SqlFunction(
            IsDeterministic = true,
            IsPrecise = true,
            DataAccess = DataAccessKind.None,
            SystemDataAccess = SystemDataAccessKind.None
            )]
        public static bool? IsMarked(string group, string code) {
            return code == null
                ? null
                : code.Length > 3 && code[3] == 'M';
        }

        // The same check with SqlString arguments, which are not converted to System.String.
        [SqlFunction(
            IsDeterministic = true,
            IsPrecise = true,
            DataAccess = DataAccessKind.None,
            SystemDataAccess = SystemDataAccessKind.None
            )]
        public static SqlBoolean IsMarkedSql(SqlString group, SqlString code) {
            if (code.IsNull) {
                return SqlBoolean.Null;
            }
            string s = code.Value;
            return s.Length > 3 && s[3] == 'M';
        }

        // The same check with SqlChars arguments, which stream an nvarchar(max) value rather than copy it
        // into a string: it reads only the one character it tests.
        [SqlFunction(
            IsDeterministic = true,
            IsPrecise = true,
            DataAccess = DataAccessKind.None,
            SystemDataAccess = SystemDataAccessKind.None
            )]
        public static bool? IsMarkedChars(SqlChars group, SqlChars code) {
            return code.IsNull
                ? null
                : code.Length > 3 && code[3] == 'M';
        }

        // No strings at all.
        [SqlFunction(
            IsDeterministic = true,
            IsPrecise = true,
            DataAccess = DataAccessKind.None,
            SystemDataAccess = SystemDataAccessKind.None
            )]
        public static int AddOne(int x) {
            return x + 1;
        }

        // A real function's parse: the text between the last endDelim and the last startDelim before it,
        // or null. It searches the whole value whenever endDelim is absent, as it is from most values.
        [SqlFunction(
            IsDeterministic = true,
            IsPrecise = true,
            DataAccess = DataAccessKind.None,
            SystemDataAccess = SystemDataAccessKind.None
            )]
        public static string ParseFromEnd(string s, string startDelim, string endDelim) {
            if (s == null) {
                return null;
            }
            int j = s.LastIndexOf(endDelim, StringComparison.Ordinal);
            if (j < 1) {
                return null;
            }
            int i = j - startDelim.Length;
            if (i < 0) {
                return null;
            }
            i = s.LastIndexOf(startDelim, i, StringComparison.Ordinal);
            if (i == -1) {
                return null;
            }
            i += startDelim.Length;
            return s.Substring(i, j - i);
        }

        // ParseFromEnd reading a SqlChars backward through one small window, so whatever the value's length
        // it allocates only the window and the result.
        [SqlFunction(
            IsDeterministic = true,
            IsPrecise = true,
            DataAccess = DataAccessKind.None,
            SystemDataAccess = SystemDataAccessKind.None
            )]
        public static string ParseFromEndChars(SqlChars s, string startDelim, string endDelim) {
            if (s.IsNull) {
                return null;
            }
            if (startDelim.Length == 0 || endDelim.Length == 0) {
                return ParseFromEnd(s.ToSqlString().Value, startDelim, endDelim);
            }
            var window = new char[(int)Math.Min(256 + Math.Max(startDelim.Length, endDelim.Length), s.Length)];
            long j = FindLast(s, window, endDelim, s.Length);
            if (j < 1) {
                return null;
            }
            long i = j - startDelim.Length;
            if (i < 0) {
                return null;
            }
            long k = FindLast(s, window, startDelim, i + 1);
            if (k == -1) {
                return null;
            }
            k += startDelim.Length;
            int n = (int)(j - k);
            var result = n <= window.Length ? window : new char[n];
            s.Read(k, result, 0, n);
            return new string(result, 0, n);
        }

        // The last position at which value lies wholly before end, reading s backward through window; -1 if
        // there is none.
        private static long FindLast(SqlChars s, char[] window, string value, long end) {
            long hi = end;
            while (hi >= value.Length) {
                long lo = Math.Max(0, hi - window.Length);
                int n = (int)(hi - lo);
                s.Read(lo, window, 0, n);
                for (int p = n - value.Length; p >= 0; p--) {
                    int q = 0;
                    while (q < value.Length && window[p + q] == value[q]) {
                        q++;
                    }
                    if (q == value.Length) {
                        return lo + p;
                    }
                }
                if (lo == 0) {
                    break;
                }
                // overlap the next chunk by one less than the value, so a match across the boundary is found
                hi = lo + value.Length - 1;
            }
            return -1;
        }
    }
}
