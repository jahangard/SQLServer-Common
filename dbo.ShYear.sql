-- =============================================
-- Get Persian Year Persian (Shamsi) to Gregorian (Miladi) Date
-- Author:	Mehdi Jahangard
-- Date:	2015-05-07
-- Ver:		1.0	(2015-05-07)	
-- Exmp: 	
-- =============================================


SET QUOTED_IDENTIFIER, ANSI_NULLS ON
GO
CREATE FUNCTION [dbo].[ShYear](@Expression DATETIME)
RETURNS INT
AS
BEGIN
	RETURN dbo.ShDateName('YYYY', @Expression)
END

GO