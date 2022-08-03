-- =============================================
-- Return Date Time AS Date with Time 00:00:00
-- Author:	Mehdi Jahangard
-- Date:	2015-05-07
-- Ver:		1.0	(2015-05-07)	
-- =============================================


SET QUOTED_IDENTIFIER, ANSI_NULLS ON
GO
CREATE FUNCTION [dbo].[fDateOf] (@AsOfDATE DATETIME)
RETURNS DATETIME
AS
BEGIN
	RETURN CAST(FLOOR(CAST(@AsOfDATE AS FLOAT)) AS DATETIME)
END

GO