using System.Data.SqlTypes;
using Microsoft.SqlServer.Server;

namespace ClrSpin {
    // Trivial scalar functions: each does a few character or integer comparisons, so any cost per call
    // beyond that is the engine's cost of calling into the CLR.
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
    }
}
