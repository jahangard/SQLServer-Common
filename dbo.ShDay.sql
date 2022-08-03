-- =============================================
-- Get Persian Day of Gregorian (Miladi) Date to Persian (Shamsi)
-- Author:	Mehdi Jahangard
-- Date:	2015-05-07
-- Ver:		1.0	(2015-05-07)	
-- =============================================

SET QUOTED_IDENTIFIER, ANSI_NULLS ON
GO
CREATE FUNCTION [dbo].[ShDay](@Expression DATETIME)
RETURNS INT
AS
BEGIN
	RETURN dbo.ShDateName('D', @Expression)
END


GO