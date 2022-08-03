-- =============================================
-- Convert Gregorian (Miladi) Date to Persian (Shamsi)
-- Author:	Mehdi Jahangard
-- Date:	2015-05-07
-- Ver:		1.0	(2015-05-07)	
-- =============================================

SET QUOTED_IDENTIFIER, ANSI_NULLS ON
GO
CREATE FUNCTION [dbo].[ShDateToStr](@Date DATETIME)
RETURNS VARCHAR(10)
AS
BEGIN
	DECLARE
	@Result CHAR(10),
	@DD     NUMERIC, 
	@S        INT, 
	@M       INT, 
	@R       INT, 
	@TMP  VARCHAR(10), 
	@tmp1  NUMERIC, 
	@tmp2  NUMERIC

	SET @tmp1 = CONVERT(NUMERIC, DATEADD(yy, 200, DATEADD(hh, -12, @Date)))
   	SET @tmp2 = CONVERT(NUMERIC, CAST('18360320' AS DATETIME))
   	SET @DD = @tmp1- @tmp2
   	SET @S = ( FLOOR(@DD/46751)) * 128  +  1015
   	SET @DD =  @Dd - FLOOR(@DD/ 46751) * 46751
   	SET @S = ( FLOOR(@DD/12053)) * 33  + @S
   	SET @DD =  @DD - FLOOR(@Dd/12053) * 12053
   	IF @DD > 1826 
   		BEGIN
      			SET @DD = @DD - 1826
      			SET @S  = @S  +  5  +  FLOOR(@DD /1461) * 4
      			SET @DD = @Dd - FLOOR(@Dd/1461) * 1461
   		END
   	IF @DD > 365
   		BEGIN
      			SET @DD = @DD - 1
      			SET @S = @S  +  FLOOR(@DD / 365)
      			SET @DD =  @Dd - FLOOR(@DD/365) * 365
   		END
   	IF @DD > 185
   		BEGIN
      			SET @DD = @DD - 186
      			SET @R = @Dd - FLOOR(@DD/30) * 30  +  1
      			SET @M = FLOOR(@DD/30)  + 7
   		END
   	ELSE
   		BEGIN
      			SET @R = @Dd - FLOOR(@DD/31) * 31  +  1
      			SET @M = FLOOR(@DD/31)  + 1;
   		END
   	IF @M < 10
      		SET @tmp = CAST(@S AS CHAR(4)) + '/0' + CAST(@M AS CHAR(1))
   	ELSE
      		SET @tmp = CAST(@S AS CHAR(4)) + '/' + CAST(@M AS CHAR(2))
   	IF @R < 10
      		SET @Result = @tmp + '/0'  + CAST(@R AS CHAR(1))
   	ELSE
      		SET @Result = @tmp + '/'  + CAST(@R AS CHAR(2))

    SET @Result = SUBSTRING(@Result, 1, 10)

   	RETURN(@Result)


END


GO