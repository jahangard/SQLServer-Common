-- =============================================
-- Get Convert Persian (Shamsi) to Gregorian (Miladi) Date
-- Author:	Mehdi Jahangard
-- Date:	2015-05-07
-- Ver:		1.0	(2015-05-07)	
-- Exmp: 	
-- =============================================


SET QUOTED_IDENTIFIER, ANSI_NULLS ON
GO
CREATE FUNCTION [dbo].[ShStrToDate](@Date CHAR(10)) 
RETURNS DATETIME
AS
BEGIN

  IF SUBSTRING(@Date, 1, 1) <> '1'
    SET @Date = '13' + @Date;

  DECLARE
    @Result DATETIME,
    @DD   NUMERIC, 
    @S      INT, 
    @M     INT, 
    @R     INT, 
    @TMP VARCHAR(100);

  SET @S  = SUBSTRING(@Date, 1, 4);
  SET @M = SUBSTRING(@Date, 6, 2)-1;
  SET @R = SUBSTRING(@Date, 9, 2)-1;
  SET @DD = @R  +  @M * 30; 
  IF @M > 5 
    SET @DD = @DD + 6;
  ELSE
    SET @DD = @DD + @M;
   	SET @S = @S-1015;
   	SET @DD = @DD  +  ( FLOOR(@S /128))  * 46751; 
   	SET @S =    @S % 128;
   	SET @DD = @DD  +  ( FLOOR(@S /33)) * 12053;
   	SET @S =   @S % 33;
   	IF @S  >  5 
    BEGIN
      SET @S = @S - 5;
      SET @DD = @DD  +  1826  +  FLOOR(@S/4) * 1461;
      SET @S = @S%4;
    END;
   	IF @S > 0 
   	BEGIN
      SET @DD = @DD + 1;
      SET @DD = @DD  +  @S * 365;
   	END;

   	SET @Result = DATEADD(yy, -200, DATEADD(DAY, @DD, CAST('18360320' AS DATETIME)));
   	SET  @tmp = DATENAME(YEAR, @Result) + '/' + DATENAME(mm, @Result) + '/' + DATENAME(dd, @Result);

 	RETURN(@Result);
 END;


GO