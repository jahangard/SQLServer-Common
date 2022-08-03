-- =============================================
-- Get Formatted of Gregorian (Miladi) Date to Persian (Shamsi)
-- Author:	Mehdi Jahangard
-- Date:	2015-05-07
-- Ver:		1.0	(2015-05-07)	
-- Exmp: 	select dbo.ShFormatDateTime('YYYY/MM/DD HH:NN:SS')
-- =============================================

SET QUOTED_IDENTIFIER, ANSI_NULLS ON
GO
CREATE FUNCTION [dbo].[ShFormatDateTime](@FormatMask VARCHAR(32), @Expression DATETIME)

RETURNS VARCHAR(100)
AS
BEGIN
	DECLARE @StringDate VARCHAR(32)

	SET @StringDate = @FormatMask

	IF (CHARINDEX ('DDDDD',@StringDate) > 0)
	   SET @StringDate = REPLACE(@StringDate, 'DDDDD', dbo.fn_NumToAlphabet(dbo.SHDATEPART('D', @Expression)))

	IF (CHARINDEX ('DDDD',@StringDate) > 0)
	   SET @StringDate = REPLACE(@StringDate, 'DDDD', dbo.SHDATEPART('DDDD', @Expression))

	IF (CHARINDEX ('DD',@StringDate) > 0)
	   SET @StringDate = REPLACE(@StringDate, 'DD', dbo.SHDATEPART('DD', @Expression))

	IF (CHARINDEX ('D',@StringDate) > 0)
	   SET @StringDate = REPLACE(@StringDate, 'D', dbo.SHDATEPART('D', @Expression))

	IF (CHARINDEX ('MMMM',@StringDate) > 0)
	   SET @StringDate = REPLACE(@StringDate, 'MMMM', dbo.SHDATEPART('MMMM', @Expression))

	IF (CHARINDEX ('MM',@StringDate) > 0)
	   SET @StringDate = REPLACE(@StringDate, 'MM', dbo.SHDATEPART('MM', @Expression))

	IF (CHARINDEX ('M',@StringDate) > 0)
	   SET @StringDate = REPLACE(@StringDate, 'M', dbo.SHDATEPART('M', @Expression))

	IF (CHARINDEX ('YYYY',@StringDate) > 0)
	   SET @StringDate = REPLACE(@StringDate, 'YYYY', dbo.SHDATEPART('YYYY', @Expression))

	IF (CHARINDEX ('YY',@StringDate) > 0)
	   SET @StringDate = REPLACE(@StringDate, 'YY', dbo.SHDATEPART('YY', @Expression))

	IF (CHARINDEX ('HH',@StringDate) > 0)
	   SET @StringDate = REPLACE(@StringDate, 'HH', RIGHT('0'+CAST(DATEPART(hour, @Expression) as varchar(2)),2))

	IF (CHARINDEX ('H',@StringDate) > 0)
	   SET @StringDate = REPLACE(@StringDate, 'H', CAST(DATEPART(hour, @Expression) as varchar(2)))

	IF (CHARINDEX ('NN',@StringDate) > 0)
	   SET @StringDate = REPLACE(@StringDate, 'NN', RIGHT('0'+CAST(DATEPART(MINUTE, @Expression) as varchar(2)),2))

	IF (CHARINDEX ('N',@StringDate) > 0)
	   SET @StringDate = REPLACE(@StringDate, 'N', CAST(DATEPART(MINUTE, @Expression) as varchar(2)))

	IF (CHARINDEX ('SS',@StringDate) > 0)
	   SET @StringDate = REPLACE(@StringDate, 'SS', RIGHT('0'+CAST(DATEPART(SECOND, @Expression) as varchar(2)),2))

	IF (CHARINDEX ('S',@StringDate) > 0)
	   SET @StringDate = REPLACE(@StringDate, 'S', CAST(DATEPART(SECOND, @Expression) as varchar(2)))



RETURN @StringDate	
END


GO