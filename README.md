なんとまだ動作確認していない, USB経由で行けるのか微妙．<br>
(sudo) ./check_bad_sectors [-h] [device]<br>
オプションなしだと全ドライブに走る<br>
セクタチェックと，環境変数TEST_MBの分だけ読み書きする(デフォは1GB)<br>

以下使い方ガイド．<br>
ディスクの初期化，使用するOSに応じてフォーマットを行っていることを前提として<br>
- for Windows<br>
テストで書き込みを行うのでドライブレターを付与してもらってから、<br>
管理者実行のPowershellで<br>
```Get-Disk```<br>
<img width="840" height="137" alt="image" src="https://github.com/user-attachments/assets/2a7419a8-86f9-44e4-9f29-1acb09d54356" /><br>
テストしたいHDDに割り当てられている番号を確認する<br>
確認したらプロジェクトのルートで，<br>
```.\check_bad_sectors.ps1 pd<ディスク番号>```<br>
<img width="586" height="72" alt="image" src="https://github.com/user-attachments/assets/0f21a918-c2a9-4f6c-8cfc-d59a7292098f" /><br>
不良セクタが0で、IOのテストがOKになっていれば成功<br>

