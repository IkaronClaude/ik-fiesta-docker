SET IDENTITY_INSERT Account.dbo.tUser ON;
INSERT INTO Account.dbo.tUser (nUserNo, sUserID, sUserPW) VALUES (100, 'Ikaron', '941dac874daf41cc0692afed768a9db1');
SET IDENTITY_INSERT Account.dbo.tUser OFF;
SELECT nUserNo, sUserID FROM Account.dbo.tUser;
