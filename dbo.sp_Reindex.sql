SET QUOTED_IDENTIFIER, ANSI_NULLS ON
GO

CREATE PROCEDURE [dbo].[p_RebuildAll] 

AS
BEGIN
	EXEC sys.sp_MSforeachtable 'ALTER INDEX ALL ON ? REBUILD; Print ''Table ? Index Rebuilded'''
END;
GO