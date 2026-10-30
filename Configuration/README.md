# 開発用Internet接続のローカル設定

`Debug.xcconfig`はAppのDebug構成だけが使う。optional includeする`Debug.local.xcconfig`はこのMacだけの試用設定で、Gitのignore対象とする。資格を文書・ソースへ貼り付けない。

ローカル設定の`RIDEINTERCOM_DEVELOPMENT_WORKER_HOST`にHTTPS接続先のhost、`RIDEINTERCOM_DEVELOPMENT_ACCESS_TOKEN`に試用tokenを設定する。後者は`[sdk=macosx*]`と`[sdk=iphone*]`でmacOS / iOSの値を分ける。発行済みの端末JSONから設定でき、App画面への手入力は不要。

Debugの通常ビルドだけが対象platformの値を生成Info.plistへ取り込む。Release・Archive・隔離された検証buildへは含めない。設定ファイル自体はApp resourceとしてコピーしない。

ファイルがなければ未設定のままビルドできる。既定値はKeychainへ自動保存せず、明示保存された設定を優先する。実Cloudflareを使う前には、単体・結合を含むローカル検証をすべて成功させる。
