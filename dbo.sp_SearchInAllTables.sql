
--SELECT ABS(CHECKSUM(NEWID()))  
--Parameters: @StringToSearchFor - string to search for e.g. '%<TextForSearch>%' or '<TextForSearch>' or '%<TextForSearch>' and etc

CREATE PROC [dbo].[p_SearchInAllTables] @SearchStr NVARCHAR(255)
AS


BEGIN
    -- Do not lock anything, and do not get held up by any locks.
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED
    
    SET NOCOUNT ON
    
    CREATE TABLE #Results
    (
    	TableName NVARCHAR(256), ColumnName NVARCHAR(128), ColumnValue NVARCHAR(3630)
    )
    
    DECLARE @TableName NVARCHAR(256)='', @ColumnName NVARCHAR(128), @ExecStr NVARCHAR(1024)
    --SET  @TableName = ''
    --SET @SearchStr2 = QUOTENAME('%' + @SearchStr + '%','''')
    
    WHILE @TableName IS NOT NULL
    BEGIN
        SET @ColumnName = ''
        SET @TableName = (
                SELECT MIN(QUOTENAME(TABLE_SCHEMA)+'.'+QUOTENAME(TABLE_NAME))
                FROM   INFORMATION_SCHEMA.TABLES
                WHERE  TABLE_TYPE = 'BASE TABLE'
                       AND QUOTENAME(TABLE_SCHEMA)+'.'+QUOTENAME(TABLE_NAME)>@TableName
                       AND OBJECTPROPERTY(OBJECT_ID(QUOTENAME(TABLE_SCHEMA)+'.'+QUOTENAME(TABLE_NAME)), 'IsMSShipped') = 0
            )
        
        WHILE (@TableName IS NOT NULL)
              AND (@ColumnName IS NOT NULL)
        BEGIN
            PRINT '@TableName = '+@TableName+'; @ColumnName = '+@ColumnName
            
            SET @ColumnName = (
                    SELECT MIN(QUOTENAME(COLUMN_NAME))
                    FROM   INFORMATION_SCHEMA.COLUMNS
                    WHERE  TABLE_SCHEMA = PARSENAME(@TableName, 2)
                           AND TABLE_NAME = PARSENAME(@TableName, 1)
                           AND DATA_TYPE IN ('char', 'varchar', 'nchar', 'nvarchar', 'int', 'decimal')
                           AND QUOTENAME(COLUMN_NAME)>@ColumnName
                )
            
            IF @ColumnName IS NOT NULL
            BEGIN
                --            SET @ExecStr = 'SELECT ''' + @TableName + ''',''' + @ColumnName + ''', LEFT(' + @ColumnName + ', 3630) FROM ' + @TableName + ' (NOLOCK) ' + ' WHERE ' + @ColumnName + ' LIKE ' + @SearchStr;
                PRINT '@ColumnName = '+@ColumnName
                
                SET @ExecStr = 'SELECT '''+REPLACE(REPLACE(@TableName, ']', ''), '[', '')+''','''+REPLACE(REPLACE(@ColumnName, ']', ''), '[', '')+''', LEFT('+
                    @ColumnName+', 3630) FROM '+@TableName+' (NOLOCK) '+' WHERE '+@ColumnName+' LIKE N'''+@SearchStr+'''';
                PRINT @ExecStr
                
                INSERT INTO #Results
                EXEC (@ExecStr)
            END
        END
    END
    
    SELECT TableName, ColumnName, ColumnValue
    FROM   #Results
    ORDER BY
           1, 2
    
    DROP TABLE #Results
END
GO