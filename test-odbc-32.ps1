$cs = 'DRIVER={SQL Server};SERVER=sqlserver,1433;UID=sa;PWD=YourStrong!Passw0rd'
try {
    $c = New-Object System.Data.Odbc.OdbcConnection($cs)
    $c.Open()
    'OK 32bit: ' + $c.ServerVersion
    $c.Close()
} catch {
    'ERR 32bit: ' + $_.Exception.Message
}
