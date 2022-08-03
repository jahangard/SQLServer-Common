-- =============================================
-- Decryption
-- Author:	Mehdi Jahangard
-- Date:	2015-05-07
-- Ver:		1.0	(2015-05-07)	
-- =============================================


CREATE FUNCTION [dbo].[fn_Decrypt] 
(
	@CipherText  VARBINARY(MAX),
	@Key		 NVARCHAR(255)
)
RETURNS NVARCHAR(MAX)
AS
BEGIN
	RETURN DecryptByPassphrase(@Key, @CipherText)

END



GO