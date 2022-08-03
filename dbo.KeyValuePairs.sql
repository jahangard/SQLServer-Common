-- =============================================
-- Return Table of Key Value
-- Author:	Mehdi Jahangard
-- Date:	2015-05-07
-- Ver:		1.0	(2015-05-07)	
-- =============================================


CREATE FUNCTION [dbo].[KeyValuePairs]( @inputStr NVARCHAR(MAX)) 
RETURNS @OutTable TABLE 
	(KeyName NVARCHAR(MAX), KeyValue NVARCHAR(MAX))
AS
BEGIN

	DECLARE @separator NCHAR(1), @keyValueSeperator NCHAR(1)
	SET @separator = N';'
	SET @keyValueSeperator = N','

	DECLARE @separator_position INT , @keyValueSeperatorPosition INT
	DECLARE @match NVARCHAR(MAX) 
	
	SET @inputStr = @inputStr + @separator
	
	WHILE PATINDEX(N'%' + @separator + N'%' , @inputStr) <> 0 
	 BEGIN
	  SELECT @separator_position =  PATINDEX(N'%' + @separator + N'%' , @inputStr)
	  SELECT @match = LEFT(@inputStr, @separator_position - 1)
	  IF @match <> N'' 
		  BEGIN
            SELECT @keyValueSeperatorPosition = PATINDEX(N'%' + @keyValueSeperator + N'%' , @match)
            IF @keyValueSeperatorPosition <> -1 
              BEGIN
        		INSERT @OutTable
				 VALUES (LEFT(@match,@keyValueSeperatorPosition -1), RIGHT(@match,LEN(@match) - @keyValueSeperatorPosition))
              END
		   END		
 	  SELECT @inputStr = STUFF(@inputStr, 1, @separator_position, N'')
	END

	RETURN
END
GO