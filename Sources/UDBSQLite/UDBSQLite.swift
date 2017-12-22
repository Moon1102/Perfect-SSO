import PerfectThread
import PerfectSQLite
import PerfectSSOAuth
import Foundation

typealias Exception = PerfectSSOAuth.Exception

public class UDBSQLite<Profile>: UserDatabase {
  internal let lock: Threading.Lock
  internal let db: SQLite
  internal let table: String
  internal let encoder: JSONEncoder
  internal let decoder: JSONDecoder
  struct Field {
    public var name = ""
    public var `type` = ""
  }

  internal let fields: [Field]
  /// Create a database connection and attach the user table
  /// - parameters:
  ///   - path: the file path of the sqlite3 database
  ///   - table: the table name of the user record
  ///   - sample: a sample profile for table creation
  /// - throws: Exception
  public init<Profile: Codable>(path: String, table: String, sample: Profile) throws {
    lock = Threading.Lock()
    db = try SQLite(path)
    encoder = JSONEncoder()
    decoder = JSONDecoder()
    self.table = table
    let properties = try DataworkUtility.explainProperties(of: sample)
    guard !properties.isEmpty else {
      throw Exception.Fault("invalid profile structure")
    }
    fields = try properties.map { s -> Field in
      let tp = s.typeName
      let typeName: String
      if tp.contains(string: "[") {
        typeName = "BLOB"
      } else if tp.contains(string: "Int") {
        typeName = "INTEGER"
      } else if tp.contains(string: "Float") || tp.contains(string: "Double") {
        typeName = "REAL"
      } else if tp == "String" {
        typeName = "TEXT"
      } else {
        throw Exception.Fault("incompatible type name: \(tp)")
      }
      return Field(name: s.fieldName, type: typeName)
    }
    let description:[String] = fields.map { "\($0.name) \($0.type)" }
    let fieldDescription = description.joined(separator: ",")
    let sql = """
    CREATE TABLE IF NOT EXISTS users(
    id TEXT PRIMARY KEY NOT NULL,
    salt TEXT, shadow TEXT, \(fieldDescription))
    """
    try db.execute(statement: sql)
  }

  deinit {
    db.close()
  }

  internal func exists(_ id: String) -> Bool {
    let count = (try? lock.doWithLock {
      var count = 0
      try self.db.forEachRow(statement:
        "SELECT id FROM \(self.table) WHERE id = ? LIMIT 1",
        doBindings: { stmt in
          try stmt.bind(position: 1, id)
      }) { _, _ in
        count += 1
      }
      return count
      }) ?? 0
    return count > 0
  }

  public func insert<Profile>(_ record: UserRecord<Profile>) throws {
    if exists(record.id) {
      throw Exception.Fault("user has already registered")
    }
    let data = try encoder.encode(record.profile)
    let bytes:[UInt8] = data.map { $0 }
    guard let json = String(validatingUTF8:bytes),
      let dic = try json.jsonDecode() as? [String: Any] else {
        throw Exception.Fault("json encoding failure")
    }
    try lock.doWithLock {
      let properties:[String] = fields.map { $0.name }
      let columns = ["id", "salt", "shadow"] + properties
      let qmarks:[String] = Array.init(repeating: "?", count: columns.count)
      let col = columns.joined(separator: ",")
      let que = qmarks.joined(separator: ",")
      let sql = "INSERT INTO \(table)(\(col)) VALUES(\(que))"
      try db.execute(statement: sql){
        stmt in
        try stmt.bind(position: 1, record.id)
        try stmt.bind(position: 2, record.salt)
        try stmt.bind(position: 3, record.shadow)
        for i in 0 ..< fields.count {
          let f = fields[i]
          let j = i + 4
          switch f.type {
          case "TEXT":
            let s = dic[f.name] as? String ?? ""
            try stmt.bind(position: j, s)
            break
          case "REAL":
            let s = dic[f.name] as? Double ?? 0
            try stmt.bind(position: j, s)
            break
          case "INTEGER":
            let s = dic[f.name] as? Int ?? 0
            try stmt.bind(position: j, s)
            break
          default:
            throw Exception.Fault("incompatible value type")
          }
        }
      }
    }
  }
  public func select<Profile>(_ id: String) throws -> UserRecord<Profile> {
    return try lock.doWithLock {
      var u: UserRecord<Profile>? = nil
      let columns:[String] = fields.map { $0.name }
      let col = columns.joined(separator: ",")
      try self.db.forEachRow(statement:
        "SELECT id, salt, shadow, \(col) FROM \(self.table) WHERE id = ? LIMIT 1",
        doBindings: { stmt in
          try stmt.bind(position: 1, id)
      }) { rec, _ in
        let id = rec.columnText(position: 0)
        let salt = rec.columnText(position: 1)
        let shadow = rec.columnText(position: 2)
        var dic: [String: Any] = [:]
        for i in 0 ..< fields.count {
          let fname = fields[i].name
          let j = i + 3
          switch fields[i].type {
          case "TEXT":
            dic[fname] = rec.columnText(position: j)
            break
          case "INTEGER":
            dic[fname] = rec.columnInt(position: j)
          case "REAL":
            dic[fname] = rec.columnDouble(position: j)
          default:
            throw Exception.Fault("unexpected column type: \(fields[i].type)")
          }
        }
        let json = try dic.jsonEncodedString()
        let data = Data(json.utf8)
        let profile = try decoder.decode(Profile.self, from: data)
        u = UserRecord(id: id, salt: salt, shadow: shadow, profile: profile)
      }
      guard let v = u else {
        throw Exception.Fault("record not found")
      }
      return v
    }
  }

  public func delete(_ id: String) throws {
    guard exists(id) else {
      throw Exception.Fault("user does not exists")
    }
    try lock.doWithLock {
      try db.execute(statement: "DELETE FROM \(table) WHERE id = ?"){
        stmt in
        try stmt.bind(position: 1, id)
      }
    }
  }

  public func update<Profile>(_ record: UserRecord<Profile>) throws {
    guard exists(record.id) else {
      throw Exception.Fault("user does not exists")
    }
    let data = try encoder.encode(record.profile)
    let bytes:[UInt8] = data.map { $0 }
    guard let json = String(validatingUTF8:bytes),
      let dic = try json.jsonDecode() as? [String: Any] else {
        throw Exception.Fault("json encoding failure")
    }
    try lock.doWithLock {
      let columns:[String] = fields.map { "\($0.name) = ?" }
      let sentence = columns.joined(separator: ",")
      let sql = "UPDATE \(table) SET salt = ?, shadow = ?, \(sentence) WHERE id = ?"
      try db.execute(statement: sql){
        stmt in
        try stmt.bind(position: 1, record.salt)
        try stmt.bind(position: 2, record.shadow)
        for i in 0 ..< fields.count {
          let f = fields[i]
          let j = i + 3
          switch f.type {
          case "TEXT":
            let s = dic[f.name] as? String ?? ""
            try stmt.bind(position: j, s)
            break
          case "REAL":
            let s = dic[f.name] as? Double ?? 0
            try stmt.bind(position: j, s)
            break
          case "INTEGER":
            let s = dic[f.name] as? Int ?? 0
            try stmt.bind(position: j, s)
            break
          case "BLOB":
            let s = dic[f.name] as? [Int8] ?? []
            try stmt.bind(position:j, s)
          default:
            throw Exception.Fault("incompatible value type")
          }
        }
        try stmt.bind(position: fields.count + 3, record.id)
      }
    }
  }
}
