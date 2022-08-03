-- =============================================
-- Get Part of Gregorian (Miladi) Date to Persian (Shamsi)
-- Author:	Mehdi Jahangard
-- Date:	2015-05-07
-- Ver:		1.0	(2015-05-07)	
-- =============================================


CREATE FUNCTION [dbo].[ShDatePart] 
(
	@DatePart	VARCHAR(10),
	@Expression	DATETIME
)
RETURNS VARCHAR(32)
AS
BEGIN
	DECLARE @Result VARCHAR(32)
	SET @DatePart = UPPER(@DatePart)
	
	-- برای نمایش روز بصورت تک رقم
	IF @DatePart = 'D'
	BEGIN
		SET @Result = CONVERT(INT, SUBSTRING(dbo.ShDateToStr(@Expression), 9, 2))
		GOTO COMPLATE
	END
	
	-- برای نمایش روز بصورت دو رقم
	IF @DatePart = 'DD'
	BEGIN
		SET @Result = SUBSTRING(dbo.ShDateToStr(@Expression), 9, 2)
		GOTO COMPLATE
	END

	-- برای نمایش روز بصورت اسم
	IF @DatePart = 'DDDD'
	BEGIN
		SELECT @Result = CASE DATEPART(WEEKDAY, @Expression)
			WHEN 7 THEN 'شنبه'
			WHEN 1 THEN 'یکشنبه'
			WHEN 2 THEN 'دوشنبه'
			WHEN 3 THEN 'سه شنبه'
			WHEN 4 THEN 'چهارشنبه'
			WHEN 5 THEN 'پنج شنبه'
			WHEN 6 THEN 'آدینه'
		END
		
		GOTO COMPLATE
	END

	-- برای نمایش روز بصورت اسم
	IF @DatePart = 'DW'
	BEGIN
		SELECT @Result = CASE DATEPART(WEEKDAY, @Expression)
			WHEN 7 THEN 1
			WHEN 1 THEN 2
			WHEN 2 THEN 3
			WHEN 3 THEN 4
			WHEN 4 THEN 5
			WHEN 5 THEN 6
			WHEN 6 THEN 7
		END
		
		GOTO COMPLATE
	END
	
	-- برای نمایش ماه بصورت تک رقم
	IF @DatePart = 'M'
	BEGIN
		SET @Result = CONVERT(INT, SUBSTRING(dbo.ShDateToStr(@Expression), 6, 2))
		GOTO COMPLATE
	END
	
	-- برای نمایش ماه بصورت دو رقم
	IF @DatePart = 'MM'
	BEGIN
		SET @Result = SUBSTRING(dbo.ShDateToStr(@Expression), 6, 2)
		GOTO COMPLATE
	END

	-- برای نمایش ماه بصورت اسم
	IF @DatePart = 'MMMM'
	BEGIN
		SELECT @Result = CASE CONVERT(INT, SUBSTRING(dbo.ShDateToStr(@Expression), 6, 2))
			WHEN 1  THEN 'فروردین'
			WHEN 2  THEN 'اردیبهشت'
			WHEN 3  THEN 'خرداد'
			WHEN 4  THEN 'تیر'
			WHEN 5  THEN 'مرداد'
			WHEN 6  THEN 'شهریور'
			WHEN 7  THEN 'مهر'
			WHEN 8  THEN 'آبان'
			WHEN 9  THEN 'آذر'
			WHEN 10 THEN 'دی'
			WHEN 11 THEN 'بهمن'
			WHEN 12 THEN 'اسفند'
		END
		
		GOTO COMPLATE
	END

	-- برای نمایش سال بصورت دو رقم
	IF @DatePart = 'YY'
	BEGIN
		--SET @Result = SUBSTRING(dbo.ShDateToStr(@Expression), 3, 2)
	    SET @Result = SUBSTRING(dbo.ShDateToStr(@Expression), 1, 4)
		GOTO COMPLATE
	END
	
	-- برای نمایش سال بصورت چهار رقم
	IF @DatePart = 'YYYY'
	BEGIN
		SET @Result = SUBSTRING(dbo.ShDateToStr(@Expression), 1, 4)
		GOTO COMPLATE
	END

	-- روزهای سپری شده از اول سال
	IF @DatePart = 'DY'
	BEGIN
		SET @Result = DATEDIFF(DAY, dbo.ShStrToDate(dbo.ShDatePart('YYYY', @Expression) + '/01/01'), @Expression)
		GOTO COMPLATE
	END

	-- هفته های سپری شده از اول سال
	IF @DatePart = 'WY'
	BEGIN
		SET @Result = DATEDIFF(WEEK, dbo.ShStrToDate(dbo.ShDatePart('YYYY', @Expression) + '/01/01'), @Expression)
		GOTO COMPLATE
	END


COMPLATE:
	RETURN @Result
END


GO