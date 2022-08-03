-- =============================================
-- Encryption
-- Author:	Mehdi Jahangard
-- Date:	2015-05-07
-- Ver:		1.0	(2015-05-07)	
-- =============================================

CREATE FUNCTION [dbo].[fn_Encrypt] 
(
	@ClearText NVARCHAR(MAX),
	@Key	   NVARCHAR(255)
)
RETURNS VARBINARY(MAX)
AS
BEGIN
	RETURN EncryptByPassPhrase(@Key, @ClearText)
END




GO