part of mongo_dart;
class Db{
  String databaseName;
  ServerConfig serverConfig;
  Connection connection;
  _validateDatabaseName(String dbName) {
    if(dbName.length === 0) throw "database name cannot be the empty string";
    var invalidChars = [" ", ".", "\$", "/", "\\"];
    for(var i = 0; i < invalidChars.length; i++) {
      if(dbName.indexOf(invalidChars[i]) != -1) throw new Exception("database names cannot contain the character '${invalidChars[i]}'");
    }
  }

/**
* Db constructor expects [valid mongodb URI] (http://www.mongodb.org/display/DOCS/Connections).
* For example next code points to local mongodb server on default mongodb port, database *testdb*
*     var db = new Db('mongodb://127.0.0.1/testdb');
* And that code direct to MongoLab server on 37637 port, database *testdb*, username *dart*, password *test*
*     var db = new Db('mongodb://dart:test@ds037637-a.mongolab.com:37637/objectory_blog');
*/
  Db(String uriString){
    _configureConsoleLogger();
    var uri = new Uri.fromString(uriString);
    if (uri.scheme != 'mongodb') {
      throw 'Invalid scheme in uri: $uriString ${uri.scheme}';
    }
    serverConfig = new ServerConfig();
    serverConfig.host = uri.domain;
    serverConfig.port = uri.port;
    if (serverConfig.port == null || serverConfig.port == 0){
      serverConfig.port = 27017;
    }
    if (uri.userInfo != '') {
      var userInfo = uri.userInfo.split(':');
      if (userInfo.length != 2) {
        throw 'Неверный формат поля userInfo: $uri.userInfo';
      }
      serverConfig.userName = userInfo[0];
      serverConfig.password = userInfo[1];
    }
    if (uri.path != '') {
      databaseName = uri.path.replaceAll('/','');
    }
    connection = new Connection(serverConfig);
  }
  DbCollection collection(String collectionName){
      return new DbCollection(this,collectionName);
  }
  Future queryMessage(MongoMessage queryMessage){
    return connection.query(queryMessage);
  }
  executeMessage(MongoMessage message){
    connection.execute(message);
  }
  Future open(){
    Completer completer = new Completer();
    initBsonPlatform();
    if (connection.connected){
      connection.close();
      connection = new Connection(serverConfig);
    }
    connection.connect().then((v) {
      if (serverConfig.userName === null) {
        completer.complete(v);
      }
      else {
        authenticate(serverConfig.userName,serverConfig.password).then((v) {
          completer.complete(v);
        });
      }
    });
    return completer.future;
  }
  Future executeDbCommand(MongoMessage message){
      Completer<Map> result = new Completer();
      connection.query(message).then((replyMessage){
        String errMsg;
        if (replyMessage.documents.length == 0) {
          errMsg = "Error executing Db command, Document length 0 $replyMessage";
          print("Error: $errMsg");
          var m = new Map();
          m["errmsg"]=errMsg;
          result.completeException(m);
        } else  if (replyMessage.documents[0]['ok'] == 1.0 && replyMessage.documents[0]['err'] == null){
          result.complete(replyMessage.documents[0]);
        } else {
          result.completeException(replyMessage.documents[0]);
        }
      });
    return result.future;
  }
  Future dropCollection(String collectionName){
    Completer completer = new Completer();
    collectionsInfoCursor(collectionName).toList().then((v){
      if (v.length == 1){
        executeDbCommand(DbCommand.createDropCollectionCommand(this,collectionName))
          .then((res)=>completer.complete(res));
        } else{
          completer.complete(true);
        }
    });
    return completer.future;
  }
/**
*   Drop current database
*/
  Future drop(){
    return executeDbCommand(DbCommand.createDropDatabaseCommand(this));
  }

  Future removeFromCollection(String collectionName, [Map selector = const {}]){
    return connection.query(new MongoRemoveMessage("$databaseName.$collectionName", selector));
  }

  Future<Map> getLastError(){
    return executeDbCommand(DbCommand.createGetLastErrorCommand(this));
  }
  Future<Map> getNonce(){
    return executeDbCommand(DbCommand.createGetNonceCommand(this));
  }

  Future<Map> wait(){
    return getLastError();
  }
  void close(){
//    print("closing db");
    connection.close();
  }

  Cursor collectionsInfoCursor([String collectionName]) {
    Map selector = {};
    // If we are limiting the access to a specific collection name
    if(collectionName !== null){
      selector["name"] = "${this.databaseName}.$collectionName";
    }
    // Return Cursor
      return new Cursor(this, new DbCollection(this, DbCommand.SYSTEM_NAMESPACE_COLLECTION), selector);
  }

  Future<bool> authenticate(String userName, String password){
    Completer completer = new Completer();
    getNonce().chain((msg) {
      var nonce = msg["nonce"];
      var command = DbCommand.createAuthenticationCommand(this,userName,password,nonce);
      serverConfig.password = '***********';
      return executeDbCommand(command);
    }).
    then((res)=>completer.complete(res["ok"] == 1));
    return completer.future;
  }
  Future<List> indexInformation([String collectionName]) {    
    var selector = {};
    if (collectionName != null) {
      selector['ns'] = '$databaseName.$collectionName';
    }
    return new Cursor(this, new DbCollection(this, DbCommand.SYSTEM_INDEX_COLLECTION), selector).toList();    
  }
  String _createIndexName(Map keys) {
    var name = '';
    keys.forEach((key,value) {
      name = '${name}_${key}_$value';
    });
    return name;    
  }
  Future createIndex(String collectionName, {String key, Map keys, bool unique, bool sparse, bool background, bool dropDups, String name}) {    
    var selector = {};
    selector['ns'] = '$databaseName.$collectionName';
    keys = _setKeys(key, keys);
    selector['key'] = keys;
    for (final order in keys.values) {
      if (order != 1 && order != -1) {
        throw const ArgumentError('Keys may contain only 1 or -1');  
      }
    }
    if (unique == true) { 
      selector['unique'] = true;
    } else {
      selector['unique'] = false;
    }    
    if (sparse == true) {
      selector['sparse'] = true;
    }
    if (background == true) {
      selector['background'] = true;
    }
    if (dropDups == true) {
      selector['dropDups'] = true;
    }
    if (name ==  null) {
      name = _createIndexName(keys);
    }
    selector['name'] = name;
    MongoInsertMessage insertMessage = new MongoInsertMessage('$databaseName.${DbCommand.SYSTEM_INDEX_COLLECTION}',[selector]);    
    executeMessage(insertMessage);
    return getLastError();
  }

  Map _setKeys(String key, Map keys) {    
    if (key != null && keys != null) {    
      throw const ArgumentError('Only one parameter must be set: key or keys');    
    }    
    if (key != null) {    
      keys = {'$key': 1};    
    }    
    if (keys == null) {    
      throw const ArgumentError('key or keys parameter must be set');    
    }
    return keys;    
  } 
  Future ensureIndex(String collectionName, {String key, Map keys, bool unique, bool sparse, bool background, bool dropDups, String name}) {
    keys = _setKeys(key, keys);
    var completer = new Completer();
    indexInformation(collectionName).then((indexInfos) {
      if (name == null) {
        name = _createIndexName(keys);
      }        
      if (indexInfos.some((info) => info['name'] == name)) {
        completer.complete({'ok': 1.0, 'result': 'index preexists'});
      } else {
        return createIndex(collectionName,keys: keys, unique: unique, sparse: sparse, background: background, dropDups: dropDups, name: name);
      }
    });
    return completer.future;
  }  
}

  
