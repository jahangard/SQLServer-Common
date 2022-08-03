/*
Returns
	a) Always first recordset -  one row with 4 integer columns:
		ResultCode  :
  	 	 	0 - Success                                                                              
  	  		1 - Partial success - some indexes could not be rebuilt                                  
  	  		2 - Partial success - Indexes were rebuilt, but some statistics were not updated         
 	  		5 - Invalid input parameter(s)     
	
	
		TotalIndexesToRebuild  - total count of indexes detected to be rebuild
		RebuiltWithOnlineON    - count of indexes rebuilt with option ONLINE = ON
		RebuiltWithOnlineOFF   - count of indexes rebuilt with option ONLINE = OFF  (can't be rebuilt with ONLINE = ON)
		TotalStatisticsToUpdate - total count of the indexes to update statistics for
		StatisticsUpdated - count of the number of indexes updated
	
	b) Always second recordset - see @errors table
	c) Only when @Verbose=1, then the second recordset with detailed info about all indexes 
	d) Only when @Verbose=1, then the third recordset with detailed info about all indexes to update statistics on
*/



CREATE PROCEDURE [dbo].[p_ReindexAll] 
(
    @AllIndexTypes      INT = 1,	--0:Clustered Index only, 1: Clustered and Non Clustered indexes
    @MaxRunTime         INT = NULL,	--Maximum allowed running time (in seconds)  
    @FragRebuildPct     INT = 30,	--Percentage of fragmentation at which indexes are rebuilt 
    @MinPages           INT = 25,	--do not touch tables less than 25 pages 
    @Verbose            INT = 1,	--1: Print progress messages and detailed results
    @Online             BIT = 1 --1: rebuild indexes online
)
AS
BEGIN
	SET NOCOUNT ON  
	
	DECLARE @TotalIndexesToRebuild INT = 0,
	        @RebuiltWithOnlineON INT = 0,
	        @RebuiltWithOnlineOFF INT = 0,
	        @TotalStatisticsToUpdate INT = 0,
	        @StatisticsUpdated INT = 0
	
	--Get start time for max run time tracking  
	DECLARE @MaxTime DATETIME  
	SELECT @MaxTime = DATEADD(ss, ISNULL(@MaxRunTime, 0), GETUTCDATE()) 
	
	--Account for nulls in parameters, set to default values
	SET @FragRebuildPct = ISNULL(@FragRebuildPct, 30)
	SET @AllIndexTypes = ISNULL(@AllIndexTypes, 0)
	SET @Verbose = ISNULL(@Verbose, 0)
	SET @MinPages = ISNULL(@MinPages, 25)
	SET @Online = ISNULL(@Online, 1)
	
	--Validate parameters
	IF (
	       (@MaxRunTime <= 0)
	       OR (@AllIndexTypes NOT IN (0, 1))
	       OR (@Verbose NOT IN (0, 1))
	       OR (@Online NOT IN (0, 1))
	       OR (@MinPages < 1)
	       OR (@FragRebuildPct > 100)
	       OR (@FragRebuildPct < 0)
	   )
	BEGIN
	    PRINT 'Invalid Parameter value. Valid values are:' 
	    PRINT 'MaxRunTime > 0,' 
	    PRINT 'MinPages > 0'
	    PRINT 'FragRebuildPct in {NULL,0..100}' 
	    PRINT 'AllIndexTypes in {0,1}' 
	    PRINT 'Verbose in {0,1}' 
	    PRINT 'Online in {0,1}'  
	    SELECT 5                       AS ResultCode,
	           @TotalIndexesToRebuild  AS TotalIndexesToRebuild,
	           @RebuiltWithOnlineON    AS RebuiltWithOnlineON,
	           @RebuiltWithOnlineOFF   AS RebuiltWithOnlineOFF
	    
	    RETURN 5
	END  
	
	DECLARE @indexes TABLE
	        (
	            SchemaName SYSNAME,
	            TableName SYSNAME,
	            IndexName SYSNAME,
	            OldFrag INT,
	            NewFrag INT NULL,
	            processed BIT
	        )
	
	DECLARE @updateStatistics TABLE
	        (
	            SchemaName SYSNAME,
	            TableName SYSNAME,
	            IndexName SYSNAME,
	            Processed BIT
	        )
	
	DECLARE @errors TABLE
	        (
	            Number INT,
	            Severity INT,
	            STATE INT,
	            --Message nvarchar(4000),  -- can be found by select * from sys.messages m where message_id = Number and m.language_id = 1033
	            OnlineOn BIT,
	            Statement NVARCHAR(2048)
	        )
	
	INSERT INTO @indexes
	SELECT SCHEMA_NAME(o.schema_id),
	       OBJECT_NAME(s.object_id),
	       i.name,
	       s.avg_fragmentation_in_percent,
	       NULL,
	       0
	FROM   sys.dm_db_index_physical_stats (DB_ID(), NULL, NULL, NULL, NULL) s
	       JOIN sys.objects o
	            ON  (s.object_id = o.object_id)
	       JOIN sys.indexes i
	            ON  (s.object_id = i.object_id AND s.index_id = i.index_id)
	WHERE  s.avg_fragmentation_in_percent > @FragRebuildPct -- defrag only if more than x% fragmented
	       AND i.type IN (1, @AllIndexTypes + 1) -- (1,2) -- cannot defrag non-indexes(0-heap, 1- clustered, 2-nonclustered, 3-xml)
	       AND s.page_count >= @MinPages -- select only if the index spans multiple pages
	ORDER BY
	       s.avg_fragmentation_in_percent DESC
	
	SELECT @TotalIndexesToRebuild = @@rowcount
	
	-- Get all indexes that have a datetime column which are not set to be rebuild
	INSERT INTO @updateStatistics
	SELECT SCHEMA_NAME(t.schema_id),
	       t.name,
	       i.name,
	       0
	FROM   sys.indexes             AS i WITH (NOLOCK)
	                             INNER
	       JOIN sys.index_columns  AS ic WITH (NOLOCK)
	            ON  i.object_id = ic.object_id
	            AND i.index_id = ic.index_id
	       INNER JOIN sys.columns  AS c WITH (NOLOCK)
	            ON  c.object_id = ic.object_id
	            AND c.column_id = ic.column_id
	       INNER JOIN sys.tables t WITH (NOLOCK)
	            ON  i.object_id = t.object_id
	WHERE  ic.key_ordinal = 1
	       AND c.system_type_id = 61
	       AND i.type IN (1, @AllIndexTypes + 1)
	       AND NOT EXISTS -- select only if not in the rebuild table
	           (
	               SELECT TableName
	               FROM   @indexes ind
	               WHERE  ind.SchemaName = SCHEMA_NAME(t.schema_id)
	                      AND ind.TableName = t.Name
	                      AND ind.IndexName = i.Name
	           )
	ORDER BY
	       t.name,
	       i.name 
	
	SELECT @TotalStatisticsToUpdate = @@ROWCOUNT
	
	DECLARE @SchemaName SYSNAME,
	        @TableName SYSNAME,
	        @IndexName SYSNAME,
	        @sqlTemplate NVARCHAR(2048),
	        @sql NVARCHAR(2048)
	
	DECLARE @retry        BIT,
	        @onlineON     BIT
	
	DECLARE IndexCursor CURSOR LOCAL 
	FOR
	    SELECT SchemaName,
	           TableName,
	           IndexName
	    FROM   @indexes
	    ORDER BY
	           OldFrag DESC
	
	OPEN IndexCursor 
	FETCH NEXT FROM IndexCursor INTO @SchemaName, @TableName, @IndexName
	WHILE (
	          (@@FETCH_STATUS = 0)
	          AND ((GETUTCDATE() < @MaxTime) OR (@MaxRunTime IS NULL))
	      )
	BEGIN
	    SELECT @sqlTemplate = 'ALTER INDEX [' + @IndexName + '] ' +
	           'ON [' + @SchemaName + '].[' + @TableName + '] REBUILD WITH ' +
	           '( PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, SORT_IN_TEMPDB = OFF, ONLINE = '
	    
	    IF (@Online = 1)
	        SELECT @sql = @sqlTemplate + 'ON )'
	    ELSE
	        SELECT @sql = @sqlTemplate + 'OFF )'
	    
	    SELECT @retry = 1,
	           @onlineON = @Online
	    
	    WHILE (@retry = 1)
	    BEGIN
	        BEGIN TRY
	        	IF (@Verbose = 1)
	        	    PRINT @sql
	        	
	        	EXEC (@sql)
	        	SELECT @retry = 0
	        	IF (@onlineON = 1)
	        	    SELECT @RebuiltWithOnlineON = @RebuiltWithOnlineON + 1
	        	ELSE
	        	    SELECT @RebuiltWithOnlineOFF = @RebuiltWithOnlineOFF + 1
	        END TRY
	        BEGIN CATCH
	        	INSERT INTO @errors
	        	SELECT ERROR_NUMBER(),
	        	       ERROR_SEVERITY(),
	        	       ERROR_STATE(),
	        	       @onlineON,
	        	       @sql
	        	
	        	IF (@onlineON = 1 AND ERROR_NUMBER() = 2725)
	        	BEGIN
	        	    -- Handle the possible exception below: rebuild index offline. 			Only SQL2012 has THROW
	        	    --ErrorNumber	ErrorMessage
	        	    --2725	An online operation cannot be performed for index '?' because the index contains column '?' of data type text, ntext, image, varchar(max), nvarchar(max), varbinary(max), xml, or large CLR type. For a non-clustered index, the column could be an include column of the index. For a clustered index, the column could be any column of the table. If DROprEXISTING is used, the column could be part of a new or old index. The operation must be performed offline.
	        	    SELECT @sql = @sqlTemplate + 'OFF )'
	        	    SELECT @onlineON = 0
	        	END
	        	ELSE
	        	    SELECT @retry = 0
	        END CATCH
	    END
	    UPDATE @indexes
	    SET    processed = 1
	    WHERE  SchemaName = @SchemaName
	           AND TableName = @TableName
	           AND IndexName = @IndexName
	    
	    FETCH NEXT FROM IndexCursor INTO @SchemaName, @TableName, @IndexName
	END
	CLOSE IndexCursor
	DEALLOCATE IndexCursor
	
	-- Update the statistics for any index that contains a datetime column that wasn't rebuilt
	DECLARE UpdateCursor CURSOR LOCAL 
	FOR
	    SELECT SchemaName,
	           TableName,
	           IndexName
	    FROM   @updateStatistics
	
	OPEN UpdateCursor
	FETCH NEXT FROM UpdateCursor INTO @SchemaName, @TableName, @IndexName
	WHILE (
	          (@@FETCH_STATUS = 0)
	          AND ((GETUTCDATE() < @MaxTime) OR (@MaxRunTime IS NULL))
	      )
	BEGIN
	    SELECT @sql = 'UPDATE STATISTICS [' + @SchemaName + '].[' + @TableName + 
	           '] [' + @IndexName + ']'
	    
	    IF (@Verbose = 1)
	        PRINT @sql
	    
	    BEGIN TRY
	    	EXEC (@sql)
	    	SELECT @StatisticsUpdated = @StatisticsUpdated + 1
	    END TRY
	    BEGIN CATCH
	    	INSERT INTO @errors
	    	SELECT ERROR_NUMBER(),
	    	       ERROR_SEVERITY(),
	    	       ERROR_STATE(),
	    	       @onlineON,
	    	       @sql
	    END CATCH
	    UPDATE @updateStatistics
	    SET    Processed = 1
	    WHERE  SchemaName = @SchemaName
	           AND TableName = @TableName
	           AND IndexName = @IndexName
	    
	    FETCH NEXT FROM UpdateCursor INTO @SchemaName, @TableName, @IndexName
	END
	CLOSE UpdateCursor
	DEALLOCATE UpdateCursor
	
	IF (@Verbose = 1)
	BEGIN
	    UPDATE @indexes
	    SET    NewFrag = avg_fragmentation_in_percent
	    FROM   sys.dm_db_index_physical_stats (DB_ID(), NULL, NULL, NULL, NULL) 
	           s
	           JOIN sys.objects o
	                ON  (s.object_id = o.object_id)
	           JOIN sys.indexes i
	                ON  (s.object_id = i.object_id AND s.index_id = i.index_id)
	    WHERE  SchemaName = SCHEMA_NAME(o.schema_id)
	           AND TableName = OBJECT_NAME(s.object_id)
	           AND IndexName = i.name
	END
	
	DECLARE @ResultCode INT
	IF EXISTS(
	       SELECT *
	       FROM   @indexes
	       WHERE  processed = 0
	   )
	BEGIN
	    PRINT 'Did not process all indexes due to @MaxRunTime constraint'
	    SELECT @ResultCode = 1
	END
	ELSE 
	IF EXISTS(
	       SELECT *
	       FROM   @updateStatistics
	       WHERE  Processed = 0
	   )
	BEGIN
	    PRINT 'Did not update all statistics due to @MaxRunTime constraint'
	    SELECT @ResultCode = 2
	END
	ELSE
	BEGIN
	    SELECT @ResultCode = 0
	END
	
	
	
	-- Return results
	SELECT @ResultCode               AS ResultCode,
	       @TotalIndexesToRebuild    AS TotalIndexesToRebuild,
	       @RebuiltWithOnlineON      AS RebuiltWithOnlineON,
	       @RebuiltWithOnlineOFF     AS RebuiltWithOnlineOFF,
	       @TotalStatisticsToUpdate  AS TotalStatisticsToUpdate,
	       @StatisticsUpdated        AS StatisticsUpdated
	
	SELECT *
	FROM   @errors
	
	IF (@Verbose = 1)
	    SELECT *
	    FROM   @indexes
	    ORDER BY
	           OldFrag DESC
	
	IF (@Verbose = 1)
	    SELECT *
	    FROM   @updateStatistics
	
	RETURN @ResultCode
END

GO