SET QUOTED_IDENTIFIER, ANSI_NULLS ON
GO

CREATE procedure [dbo].[p_GetDependencies] @inputs xml 
as
/*==============================================================================

Input Format
	<Tables>
			<Table Name="a" Owner="b"/>
			<Table Name="c" Owner="d"/>
	</Tables>


How to write a reliable dependency checker (for SQL Server 2K5):

The following code accepts a collection of database objects (tables,
views, stored procedures, and functions) and can operate in one of five modes:

* Mode I (fastest): Given the collection, the script returns dependency and deployment
order for all objects in the collection. To activate this mode, first
populate #tblRequestedObjects and then set the following config values:
@IncludeAllDBObjects = 0
@IncludeDependencies = 0
@IncludeDependants = 0

* Mode II: Given the collection, the script returns all objects on which
the ones in the collection depend on, together with the dependency and
deployment order. This is done in a recursive manner to return all dependencies.
To activate this mode, first populate #tblRequestedObjects and then set
the following config values:
@IncludeAllDBObjects = 0
@IncludeDependencies = 1
@IncludeDependants = 0

* Mode III: Given the collection, the script returns all objects that depend
on the ones provided in the collection, together with the dependency and
deployment order. This is also done recursively to return all dependencies.
To activate this mode, first populate #tblRequestedObjects and then set
the following config values:
@IncludeAllDBObjects = 0
@IncludeDependencies = 0
@IncludeDependants = 1

* Mode VI: This is combination of Mode II and III. Given the collection,
the script returns all objects that depend on the ones provided in the collection,
as well as all objects on which the ones in the collection depend on.
The dependency and deployment order are returned as well. To activate this mode,
first populate #tblRequestedObjects and then set the following config values:
@IncludeAllDBObjects = 0
@IncludeDependencies = 1
@IncludeDependants = 1

* Mode V (slowest): The script returns the dependency and deployment order
of all standard objects (i.e., tables, views, procs, functions) in the database.
To activate this mode, first populate #tblRequestedObjects and then set
the following config values:
@IncludeAllDBObjects = 1
@IncludeDependencies = 0 (this parameter is NA in this case)
@IncludeDependants = 0   (this parameter is NA in this case)

The script operates as follows:
1. Collect information about all standard objects in the database (tables,
views, procs, functions) and store it in #tblAllDBRoutinesTablesViews.
2. Before finding dependencies, if @ValidateViews then all views are checked
to ensure that there are no binding issues.
3. Table #MySysdepends is created - this table will contain all dependencies
between standard database objects (even those omitted from sysdepends).
The table is initially populated with table dependencies based on FK
information, direct-dependency information from sysdepends/sql_dependencies,
and child-object dependencies from sysdepends/sql_dependencies as well.
4. Table #tblTextBasedObjects is created - this table holds the text
of all text-based objects in the database (views, functions, procs, triggers).
5. All comments are strippted out from the CREATE statement of objects in
#tblTextBasedObjects in order to search for dependencies within the text.
6. Based on the operation mode, we search for dependencies within
the comment-free text (we consider both direct dependencies as well
as dependencies via child-objects denoted as indirect-dependecies).
7. After all dependencies were found we iterate to find the dependency 
level and deployment order of all relevant objects.


Some terms and definitions:

DependencyLevel - if an object depends on another, and the latter depends
on yet another object, then when all three are plotted by the algorithm
they will have DependencyLevel 0, 1, and 2, respectively.

DeploymentOrder - this is the order in which objects should be deployed
in order to ensure that all dependants are created first.

Note: In SQL2K5 the script also takes into consideration the use of
synonyms when searching the text-body of DB objects to detect dependencies.

==============================================================================*/

SET NOCOUNT ON

-- User will populate this table with owner/schema and object names
-- or set @IncludeAllDBObjects BIT to 1.
IF OBJECT_ID('tempdb..#tblRequestedObjects') IS NOT NULL
        DROP TABLE #tblRequestedObjects

CREATE TABLE #tblRequestedObjects (
        ObjectOwnerOrSchema NVARCHAR(128) COLLATE database_default,
        ObjectName NVARCHAR(128) COLLATE database_default)



INSERT INTO #tblRequestedObjects 
SELECT Distinct
	Colname.value('@Owner','nvarchar(128)'),
	ColName.value('@Name','nVarchar(128)')
	 FROM @inputs.nodes('Tables/Table') MyAlias(ColName)


-- User: Populate #tblRequestedObjects here.
--INSERT INTO #tblRequestedObjects values('Sg', 'vwPolicy')
--INSERT INTO #tblRequestedObjects values('Sg', 'vwPolicy3')
--INSERT INTO #tblRequestedObjects values('wfe', 'vwJobVersion')
--INSERT INTO #tblRequestedObjects values('inv', 'vwPart')
--INSERT INTO #tblRequestedObjects values('dbo', 'DimProduct')
--INSERT INTO #tblRequestedObjects values('dbo', 'vDMPrep')
--INSERT INTO #tblRequestedObjects values('dbo', 'ISOweek')

-- The user should insert records to #tblRequestedObjects here. For example:
-- INSERT INTO #tblRequestedObjects VALUES('dbo', 'utbMyTable')
-- INSERT INTO #tblRequestedObjects SELECT USER_NAME(uid), name FROM sysobjects WHERE ...
-- Example using AdventureWorks objects:
-- INSERT INTO #tblRequestedObjects values('dbo', 'DimCustomer')
-- INSERT INTO #tblRequestedObjects values('dbo', 'DimProduct')
-- INSERT INTO #tblRequestedObjects values('dbo', 'vDMPrep')
-- INSERT INTO #tblRequestedObjects values('dbo', 'ISOweek')


DECLARE @IncludeAllDBObjects BIT
DECLARE @IncludeDependencies BIT       -- objects on which a current object depends on that are not in #tblRequestedObjects
DECLARE @IncludeDependants BIT         -- objects that depend on a current object that are not in #tblRequestedObjects
DECLARE @IncludeReplicationObjects BIT -- set this bit to 0 to not consider replication objects
DECLARE @ReturnFoundDependencies BIT
DECLARE @ReturnDeploymentOrder BIT
DECLARE @IncludeWarningForCircularDependencies BIT
DECLARE @ValidateViews BIT

-- User configuration- set the mode of operation of the algorithm:
-- 1) @IncludeAllDBObjects -  set this pamameter to 1 if you wish to find dependencies between all
--    database objects and not only the ones specified earlier in #tblRequestedObjects
-- 2) @IncludeWarningForCircularDependencies - set this parameter to 1 to return a result set
--    with all circular dependencies
-- 3) @IncludeDependencies - set to 1 to find all objects on which the objects in #tblRequestedObjects depend on.
-- 4) @IncludeDependants   - set to 1 to find all objects that depend on the objects in #tblRequestedObjects.
-- 5) @IncludeReplicationObjects - set to 1 to include replicatin objects (not recommended).
-- 6) @ReturnFoundDependencies - return a result set with all found dependencies.
-- 7) @IncludeWarningForCircularDependencies - return a result set with all circular dependencies found.
-- 8) @ValidateViews - check that the schema of all views are bound correctly (no missing underlying objects).

SET @IncludeAllDBObjects = 0
SET @IncludeDependencies = 1
SET @IncludeDependants = 0
SET @IncludeReplicationObjects = 0
SET @ReturnFoundDependencies = 1
SET @ReturnDeploymentOrder = 0
SET @IncludeWarningForCircularDependencies = 0
SET @ValidateViews = 1


-- Put square brackets where needed.
UPDATE #tblRequestedObjects
SET ObjectOwnerOrSchema = CASE
        WHEN LEFT(ObjectOwnerOrSchema, 1) <>  N'[' AND RIGHT(ObjectOwnerOrSchema, 1) <> N']'
        THEN N'[' + ObjectOwnerOrSchema + N']'
        WHEN LEFT(ObjectOwnerOrSchema, 1) <>  N'[' AND RIGHT(ObjectOwnerOrSchema, 1) = N']'
        THEN N'[' + ObjectOwnerOrSchema
        WHEN LEFT(ObjectOwnerOrSchema, 1) =  N'[' AND RIGHT(ObjectOwnerOrSchema, 1) <> N']'
        THEN ObjectOwnerOrSchema + N']'
        END,
        ObjectName = CASE
        WHEN LEFT(ObjectName, 1) <>  N'[' AND RIGHT(ObjectName, 1) <> N']'
        THEN N'[' + ObjectName + N']'
        WHEN LEFT(ObjectName, 1) <>  N'[' AND RIGHT(ObjectName, 1) = N']'
        THEN N'[' + ObjectName
        WHEN LEFT(ObjectName, 1) =  N'[' AND RIGHT(ObjectName, 1) <> N']'
        THEN ObjectName + N']'
        END

-- Make sure that all objects provided by the user exist in the database. If not- abort.

Delete from #tblRequestedObjects
where OBJECT_ID(ObjectOwnerOrSchema + '.' + ObjectName) IS NULL

if EXISTS(SELECT * FROM #tblRequestedObjects WHERE OBJECT_ID(ObjectOwnerOrSchema + '.' + ObjectName) IS NULL)
        AND (@IncludeAllDBObjects = 0 OR @IncludeAllDBObjects IS NULL)
BEGIN
        RAISERROR('Some of the objects provided in #tblRequestedObjects do not exist in the database. Aborting.', 16, 1)
        RETURN
END

-- #tblAllDBRoutinesTablesViews contains information about all
-- procedures, functions, tables, and views in the database
-- and is used for different purposes throughout the script.
IF OBJECT_ID('tempdb..#tblAllDBRoutinesTablesViews') IS NOT NULL
        DROP TABLE #tblAllDBRoutinesTablesViews

CREATE TABLE #tblAllDBRoutinesTablesViews (
        ObjectID INT NOT NULL PRIMARY KEY CLUSTERED,
        ObjectType NVARCHAR(32) COLLATE database_default NOT NULL,
        ObjectOwnerOrSchema NVARCHAR(128) COLLATE database_default NOT NULL,
        ObjectName NVARCHAR(128) COLLATE database_default NOT NULL,
        -- ObjectNameForLikeSearches1, 2, 3, 4 - contains a string for text searches using the LIKE clause
        ObjectNameForLikeSearches1 NVARCHAR(200) COLLATE database_default,
        ObjectNameForLikeSearches2 NVARCHAR(200) COLLATE database_default,
        ObjectNameForLikeSearches3 NVARCHAR(200) COLLATE database_default,
        ObjectNameForLikeSearches4 NVARCHAR(200) COLLATE database_default)

-- We populate the table #tblAllDBRoutinesTablesViews regardless of the user input.
-- Stored procedures and functions.
INSERT INTO #tblAllDBRoutinesTablesViews (ObjectID, ObjectOwnerOrSchema, ObjectName, ObjectType)
SELECT  OBJECT_ID('[' + ROUTINE_SCHEMA + '].[' + ROUTINE_NAME + ']'),
        ROUTINE_SCHEMA,
        ROUTINE_NAME,
        CASE
        WHEN ROUTINE_TYPE = N'PROCEDURE' THEN N'PROCEDURE'
        WHEN ROUTINE_TYPE = N'FUNCTION' THEN N'FUNCTION'
        END
FROM INFORMATION_SCHEMA.ROUTINES
WHERE OBJECTPROPERTY(OBJECT_ID('[' + ROUTINE_SCHEMA + '].[' + ROUTINE_NAME + ']'), 'IsMSShipped') = 0

-- Tables and views.
INSERT INTO #tblAllDBRoutinesTablesViews (ObjectID, ObjectOwnerOrSchema, ObjectName, ObjectType)
SELECT  OBJECT_ID('[' + TABLE_SCHEMA + '].[' + TABLE_NAME + ']'),
        TABLE_SCHEMA,
        TABLE_NAME,
        CASE
        WHEN TABLE_TYPE = N'VIEW' THEN N'VIEW'
        WHEN TABLE_TYPE  = N'BASE TABLE' THEN N'TABLE'
        END
FROM INFORMATION_SCHEMA.TABLES
WHERE OBJECTPROPERTY(OBJECT_ID('[' + TABLE_SCHEMA + '].[' + TABLE_NAME + ']'), 'IsMSShipped') = 0


-- View validation:
-- If @ValidateViews = 1 then we check if the view has any binding issues
-- (e.g., to make sure that objects references in the views exist in the database).
-- If any errors occur during the view validation, the entire script will stop
-- and inform the user of issues with the problematic view.

DECLARE @sSPID NVARCHAR(128)
DECLARE @CurrObjectID INT
DECLARE @CurrObjectName NVARCHAR(128)
DECLARE @CurrObjectType NVARCHAR(128)
DECLARE @CurrObjectOwnerOrSchema NVARCHAR(128)

SELECT @CurrObjectID = MIN(ObjectID)
FROM #tblAllDBRoutinesTablesViews
WHERE ObjectType = 'VIEW'

IF @ValidateViews = 1
BEGIN
        WHILE @CurrObjectID IS NOT NULL
        BEGIN
                SELECT  @CurrObjectOwnerOrSchema = REPLACE(ObjectOwnerOrSchema, '''', ''''''),
                        @CurrObjectName = REPLACE(ObjectName, '''', '''''')
                FROM #tblAllDBRoutinesTablesViews
                WHERE ObjectID = @CurrObjectID
                
                EXEC('IF EXISTS(SELECT TOP 1 * FROM [' + @CurrObjectOwnerOrSchema + '].[' + @CurrObjectName + ']) print(''View [' + @CurrObjectOwnerOrSchema + '].[' + @CurrObjectName + '] validated'')')

                IF @@ERROR <> 0
                BEGIN
                        RAISERROR('View [%s].[%s] references objects that are not available in the underlying database.', 16, 1, @CurrObjectOwnerOrSchema, @CurrObjectName)
                        RETURN
                END

                SELECT @CurrObjectID = MIN(ObjectID)
                FROM #tblAllDBRoutinesTablesViews
                WHERE ObjectID > @CurrObjectID
                        AND ObjectType = 'VIEW'
        END
END



-- #tblObjects includes all objects that need to be considered for dependency tracking:
-- Initially the table contains all the objects that are requested by the user
-- (i.e., if @IncludeAllDBObjects = 1 then #tblObjects contains all DB objects; otherwise
-- it will only include objects in #tblRequestedObjects).
-- Later, the table will include the dependencies and dependants, as requested by the user.
-- NOTE: ENTRIES IN #tblObjects DO NOT CONTAIN THE DEPENDENCY OR DEPLOYMENT ORDER !!!
IF OBJECT_ID('tempdb..#tblObjects') IS NOT NULL
        DROP TABLE #tblObjects

CREATE TABLE #tblObjects (
        ObjectID INT NOT NULL PRIMARY KEY CLUSTERED,
        ObjectOwnerOrSchema NVARCHAR(128) COLLATE database_default NOT NULL,
        ObjectName NVARCHAR(128) COLLATE database_default NOT NULL,
        ObjectType NVARCHAR(128) COLLATE database_default NOT NULL,
        -- AuxiliaryOrdering is used for deployment order and accepts the following values:
        -- 1 for tables, 2 views, 3 functions, 4 procs.
        AuxiliaryOrdering INT NOT NULL, 
        -- ObjectNameForLikeSearches1, 2, 3, 4 - contains a string for text searches using the LIKE clause
        ObjectNameForLikeSearches1 NVARCHAR(128) COLLATE database_default,
        ObjectNameForLikeSearches2 NVARCHAR(128) COLLATE database_default,
        ObjectNameForLikeSearches3 NVARCHAR(128) COLLATE database_default,
        ObjectNameForLikeSearches4 NVARCHAR(128) COLLATE database_default)


-- #tblObjects contains the objects that have to be considered for dependency checks.
-- If @IncludeAllDBObjects = 1 then #tblObjects contains all database objects;
-- otherwise #tblObjects only contains the objects requested in #tblRequestedObjects.
IF @IncludeAllDBObjects = 1
BEGIN
        -- In this case, #tblObjects includes all DB objects
        INSERT INTO #tblObjects (ObjectID, ObjectOwnerOrSchema, ObjectName, ObjectType, AuxiliaryOrdering)
        SELECT  ObjectID, ObjectOwnerOrSchema, ObjectName, ObjectType,
                CASE    WHEN ObjectType = 'TABLE' THEN 1
                        WHEN ObjectType = 'VIEW' THEN 2
                        WHEN ObjectType = 'PROCEDURE' THEN 3
                        WHEN ObjectType = 'FUNCTION' THEN 4
                END
        FROM #tblAllDBRoutinesTablesViews
END
ELSE
BEGIN
        -- Here, #tblObjects only includes the requested objects
        INSERT INTO #tblObjects (ObjectID, ObjectOwnerOrSchema, ObjectName, ObjectType, AuxiliaryOrdering)
        SELECT  a.ObjectID, a.ObjectOwnerOrSchema, a.ObjectName, a.ObjectType,
                CASE    WHEN ObjectType = 'TABLE' THEN 1
                        WHEN ObjectType = 'VIEW' THEN 2
                        WHEN ObjectType = 'PROCEDURE' THEN 3
                        WHEN ObjectType = 'FUNCTION' THEN 4
                END
        FROM #tblAllDBRoutinesTablesViews a
                INNER JOIN #tblRequestedObjects z
                ON '[' + a.ObjectOwnerOrSchema + ']' = z.ObjectOwnerOrSchema
                        AND '[' + a.ObjectName + ']' = z.ObjectName
END



-- sys.sql_dependencies does not include information about tables and FK dependencies, and does not
-- track dependencies between objects caused by child-object dependencies.
-- #MySysdepends is our interpretation of database object dependencies, and initially includes:
-- All dependency information from sys.sql_dependencies.
-- Table dependencies caused by FK constraints (which is not in sys.sql_dependencies)
-- Dependencies caused by child-objects.
--
-- Note!: #MySysdepends contains dependency information for all relevant objects in #tblObjects.

--===================================================================
-- Step 1 Start
--===================================================================

DECLARE @Cnt INT
DECLARE @Cnt1 INT
DECLARE @Cnt2 INT
DECLARE @tmpSQLStr VARCHAR(8000)
DECLARE @StopLoop BIT

SET @sSPID = CAST(@@SPID AS VARCHAR(32))

IF OBJECT_ID('tempdb..#MySysdepends') IS NOT NULL
        DROP TABLE #MySysdepends

CREATE TABLE #MySysdepends (
        id INT NOT NULL,
        depid INT NOT NULL,
        -- depType holds the type of dependency:
        -- 'D' - direct dependency between 2 objects, as found in sys.sql_dependencies
        -- 'C' - dependency via child object, as found from sys.sql_dependencies
        -- 'S' - direct dependency as found in the text-based dependency checks
        -- 'T' - dependency via child objects as concluded from the text-based dependency check.
        depType CHAR(1) COLLATE database_default NOT NULL, 
        idObjectOwnerOrSchema NVARCHAR(128) COLLATE database_default NOT NULL,
        idObjectName NVARCHAR(128) COLLATE database_default NOT NULL,
        idObjectType NVARCHAR(128) COLLATE database_default NOT NULL,
        idObjectNameForLikeSearches1 NVARCHAR(200) COLLATE database_default,
        idObjectNameForLikeSearches2 NVARCHAR(200) COLLATE database_default,
        idObjectNameForLikeSearches3 NVARCHAR(200) COLLATE database_default,
        idObjectNameForLikeSearches4 NVARCHAR(200) COLLATE database_default,
        depidObjectOwnerOrSchema NVARCHAR(128) COLLATE database_default NOT NULL,
        depidObjectName NVARCHAR(128) COLLATE database_default NOT NULL,
        depidObjectType NVARCHAR(128) COLLATE database_default NOT NULL,
        depidObjectNameForLikeSearches1 NVARCHAR(200) COLLATE database_default,
        depidObjectNameForLikeSearches2 NVARCHAR(200) COLLATE database_default,
        depidObjectNameForLikeSearches3 NVARCHAR(200) COLLATE database_default,
        depidObjectNameForLikeSearches4 NVARCHAR(200) COLLATE database_default,
        -- AuxiliaryInt is used for internal purposes.
        AuxiliaryInt INT)

EXEC('CREATE UNIQUE CLUSTERED INDEX CI_MySysdepends1' + @sSPID + ' ON #MySysdepends(id, depid)')
EXEC('CREATE UNIQUE NONCLUSTERED INDEX CI_MySysdepends2' + @sSPID + ' ON #MySysdepends(depid, id)')


-- Capture all initial dependencies:
-- 1. Table FK dependency (including self-dependency):
-- 1.1. Get all foreign tables that references tables in #tblObjects.
-- 1.2. Get all primary tables with foreign tables in #tblObjects.
INSERT INTO #MySysdepends (
        id,
        depid,
        idObjectOwnerOrSchema,
        idObjectName,
        idObjectType,
        depidObjectOwnerOrSchema,
        depidObjectName,
        depidObjectType,
        depType,
        AuxiliaryInt)
SELECT  DISTINCT OBJECT_ID('[' + a.TABLE_SCHEMA + '].[' + a.TABLE_NAME + ']'),
        OBJECT_ID('[' + c.TABLE_SCHEMA + '].[' + c.TABLE_NAME + ']'),
        a.TABLE_SCHEMA,
        a.TABLE_NAME,
        'TABLE',
        c.TABLE_SCHEMA,
        c.TABLE_NAME,
        'TABLE',
        'D',
        2
FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS a
        INNER JOIN INFORMATION_SCHEMA.REFERENTIAL_CONSTRAINTS b
        ON a.CONSTRAINT_SCHEMA = b.CONSTRAINT_SCHEMA
                AND a.CONSTRAINT_NAME = b.CONSTRAINT_NAME
        INNER JOIN INFORMATION_SCHEMA.TABLE_CONSTRAINTS c
        ON b.UNIQUE_CONSTRAINT_SCHEMA = c.CONSTRAINT_SCHEMA
                AND b.UNIQUE_CONSTRAINT_NAME = c.CONSTRAINT_NAME
        -- Only get objects of interest
        INNER JOIN #tblObjects d
        ON (OBJECT_ID('[' + a.TABLE_SCHEMA + '].[' + a.TABLE_NAME + ']') = d.ObjectID
                OR OBJECT_ID('[' + c.TABLE_SCHEMA + '].[' + c.TABLE_NAME + ']') = d.ObjectID)


-- 2) Get all dependencies from sys.sql_dependencies (only ones that were not yet recorded),
-- that relate in some way to objects in #tblObjects:
-- 2.1. Get all first-level dependencies (objects on which the items in #tblObjects depend on)

-- Dependency on tables, views, procs, functions.
-- First level/hierarchy
INSERT INTO #MySysdepends (
        id,
        depid,
        idObjectOwnerOrSchema,
        idObjectName,
        idObjectType,
        depidObjectOwnerOrSchema,
        depidObjectName,
        depidObjectType,
        depType,
        AuxiliaryInt)
SELECT DISTINCT a.ObjectID,
        c.ObjectID,
        a.ObjectOwnerOrSchema,
        a.ObjectName,
        a.ObjectType,
        c.ObjectOwnerOrSchema,
        c.ObjectName,
        c.ObjectType,
        'D', -- direct dependency
        2
FROM #tblObjects a
        INNER JOIN sys.sql_dependencies b
        ON a.ObjectID = b.[object_id]
        INNER JOIN #tblAllDBRoutinesTablesViews c
        ON b.[referenced_major_id] = c.ObjectID
        LEFT OUTER JOIN #MySysdepends x
        ON a.ObjectID = x.id
                AND c.ObjectID = x.depid
WHERE   x.id IS NULL


-- 2.2. Include child-parent object dependencies:
-- Children of objects in #tblObjects that depend on other objects.
-- Note: We do not need to consider the case where objects in #tblObjects
-- depend on children of other objects, since that is never possible.
INSERT INTO #MySysdepends (
        id,
        depid,
        idObjectOwnerOrSchema,
        idObjectName,
        idObjectType,
        depidObjectOwnerOrSchema,
        depidObjectName,
        depidObjectType,
        depType,
        AuxiliaryInt)
SELECT DISTINCT a.ObjectID,
        d.ObjectID,
        a.ObjectOwnerOrSchema,
        a.ObjectName,
        a.ObjectType,
        d.ObjectOwnerOrSchema,
        d.ObjectName,
        d.ObjectType,
        'C', -- dependency via child-object
        2
FROM #tblObjects a
        INNER JOIN sysobjects b
        ON a.ObjectID = b.parent_obj
        INNER JOIN sys.sql_dependencies c
        ON b.id = c.[object_id]
        INNER JOIN #tblAllDBRoutinesTablesViews d
        ON c.[referenced_major_id] = d.ObjectID
        LEFT OUTER JOIN #MySysdepends x
        ON a.ObjectID = x.id
                AND d.ObjectID = x.depid
WHERE   x.id IS NULL


-- 3) Hierarchical dependencies: We found objects on which items in #tblObjects
-- depend on (call these objects Set #1). We now need to find the objects 
-- on which items in Set #1 depend on, recursively.

-- Initial values to jump-start the loop below.
SET @Cnt1 = 1
SET @Cnt2 = 1

WHILE @Cnt1 > 0 OR @Cnt2 > 0
BEGIN
        UPDATE #MySysdepends
        SET AuxiliaryInt = AuxiliaryInt - 1

        -- Consider hierarchical dependencies
        INSERT INTO #MySysdepends (
                id,
                depid,
                idObjectOwnerOrSchema,
                idObjectName,
                idObjectType,
                depidObjectOwnerOrSchema,
                depidObjectName,
                depidObjectType,
                depType,
                AuxiliaryInt)
        SELECT DISTINCT a.depid,
                c.ObjectID,
                a.depidObjectOwnerOrSchema,
                a.depidObjectName,
                a.depidObjectType,
                c.ObjectOwnerOrSchema,
                c.ObjectName,
                c.ObjectType,
                'D',
                2
        FROM #MySysdepends a
                INNER JOIN sys.sql_dependencies b
                ON a.depid = b.[object_id]
                INNER JOIN #tblAllDBRoutinesTablesViews c
                ON b.[referenced_major_id] = c.ObjectID
                LEFT OUTER JOIN #MySysdepends x
                ON a.depid = x.id
                        AND c.ObjectID = x.depid
        WHERE   a.AuxiliaryInt = 1
                AND x.id IS NULL
                
        SET @Cnt1 = @@ROWCOUNT
        
        -- Include child-parent object dependencies:
        -- Children of objects in #tblObjects depend on other objects.
        -- Note: We do not need to consider the case where objects in #tblObjects
        -- depend on children of other objects, since that is never possible.
        INSERT INTO #MySysdepends (
                id,
                depid,
                idObjectOwnerOrSchema,
                idObjectName,
                idObjectType,
                depidObjectOwnerOrSchema,
                depidObjectName,
                depidObjectType,
                depType,
                AuxiliaryInt)
        SELECT DISTINCT a.depid,
                d.ObjectID,
                a.depidObjectOwnerOrSchema,
                a.depidObjectName,
                a.depidObjectType,
                d.ObjectOwnerOrSchema,
                d.ObjectName,
                d.ObjectType,
                'C',
                2
        FROM #MySysdepends a
                INNER JOIN sysobjects b
                ON a.depid = b.parent_obj
                INNER JOIN sys.sql_dependencies c
                ON b.id = c.[object_id]
                INNER JOIN #tblAllDBRoutinesTablesViews d
                ON c.[referenced_major_id] = d.ObjectID
                LEFT OUTER JOIN #MySysdepends x
                ON a.depid = x.id
                        AND d.ObjectID = x.depid
        WHERE   a.AuxiliaryInt = 1
                AND x.id IS NULL

        SET @Cnt2 = @@ROWCOUNT

END -- WHILE

-- At this point there is no need to update AuxiliaryInt
-- since all objects already have AuxiliaryInt = 1.


-- 4) Get all dependants - here we look at first level of dependants
-- (i.e., objects that depend on items in #tblObjects).

-- Dependants of the type table, view, proc, function.
INSERT INTO #MySysdepends (
        id,
        depid,
        idObjectOwnerOrSchema,
        idObjectName,
        idObjectType,
        depidObjectOwnerOrSchema,
        depidObjectName,
        depidObjectType,
        depType,
        AuxiliaryInt)
SELECT DISTINCT a.ObjectID,
        c.ObjectID,
        a.ObjectOwnerOrSchema,
        a.ObjectName,
        a.ObjectType,
        c.ObjectOwnerOrSchema,
        c.ObjectName,
        c.ObjectType,
        'D',
        2
FROM #tblAllDBRoutinesTablesViews a
        INNER JOIN sys.sql_dependencies b
        ON b.[object_id] = a.ObjectID
        INNER JOIN #tblObjects c
        ON b.[referenced_major_id] = c.ObjectID
        LEFT OUTER JOIN #MySysdepends x
        ON a.ObjectID = x.id
                AND c.ObjectID = x.depid
WHERE   x.id IS NULL


-- 5) Include child-parent object relationships.
-- Children of objects that are not in #tblObjects depend on objects in #tblObjects.
-- Note: We do not need to consider the case where objects that are not in #tblObjects
-- depend on children of objects in #tblObjects, since that is never possible.
INSERT INTO #MySysdepends (
        id,
        depid,
        idObjectOwnerOrSchema,
        idObjectName,
        idObjectType,
        depidObjectOwnerOrSchema,
        depidObjectName,
        depidObjectType,
        depType,
        AuxiliaryInt)
SELECT DISTINCT a.ObjectID,
        d.ObjectID,
        a.ObjectOwnerOrSchema,
        a.ObjectName,
        a.ObjectType,
        d.ObjectOwnerOrSchema,
        d.ObjectName,
        d.ObjectType,
        'C',
        2
FROM #tblAllDBRoutinesTablesViews a
        INNER JOIN sysobjects b
        ON a.ObjectID = b.parent_obj
        INNER JOIN sys.sql_dependencies c
        ON b.id = c.[object_id]
        INNER JOIN #tblObjects d
        ON c.[referenced_major_id] = d.ObjectID
        LEFT OUTER JOIN #MySysdepends x
        ON a.ObjectID = x.id
                AND d.ObjectID = x.depid
WHERE   x.id IS NULL


-- 6) Hierarchical dependants: We found objects that depend on items in #tblObjects
-- (denote those objects as Set #2). We now look for other objects that depend on the
-- objects in Set #2, recursively.

-- Update AuxiliaryInt before entering the loop.
UPDATE a
SET a.AuxiliaryInt = 2
FROM #MySysdepends a
        INNER JOIN #tblObjects b
        ON a.id = b.ObjectID

-- Jump-start the loop.
SET @Cnt1 = 1
SET @Cnt2 = 1

WHILE @Cnt1 > 0 OR @Cnt2 > 0
BEGIN
        UPDATE #MySysdepends
        SET AuxiliaryInt = AuxiliaryInt - 1

        -- Dependants of the type table, view, proc, function.
        -- Consider hierarchical dependencies.
        INSERT INTO #MySysdepends (
                id,
                depid,
                idObjectOwnerOrSchema,
                idObjectName,
                idObjectType,
                depidObjectOwnerOrSchema,
                depidObjectName,
                depidObjectType,
                depType,
                AuxiliaryInt)
        SELECT DISTINCT a.ObjectID,
                c.id,
                a.ObjectOwnerOrSchema,
                a.ObjectName,
                a.ObjectType,
                c.idObjectOwnerOrSchema,
                c.idObjectName,
                c.idObjectType,
                'D',
                2
        FROM #tblAllDBRoutinesTablesViews a
                INNER JOIN sys.sql_dependencies b
                ON b.[object_id] = a.ObjectID
                INNER JOIN #MySysdepends c
                ON b.[referenced_major_id] = c.id
                LEFT OUTER JOIN #MySysdepends x
                ON a.ObjectID = x.id
                        AND c.id = x.depid
        WHERE   c.AuxiliaryInt = 1
                AND x.id IS NULL
        
        SET @Cnt1 = @@ROWCOUNT

        -- Include child-parent object dependencies.
        -- Children of objects that are not in #tblObjects depend on objects in #tblObjects.
        -- Note: We do not need to consider the case where objects that are not in #tblObjects
        -- depend on children of objects in #tblObjects, since that is never possible.
        INSERT INTO #MySysdepends (
                id,
                depid,
                idObjectOwnerOrSchema,
                idObjectName,
                idObjectType,
                depidObjectOwnerOrSchema,
                depidObjectName,
                depidObjectType,
                depType,
                AuxiliaryInt)
        SELECT DISTINCT a.ObjectID,
                d.id,
                a.ObjectOwnerOrSchema,
                a.ObjectName,
                a.ObjectType,
                d.idObjectOwnerOrSchema,
                d.idObjectName,
                d.idObjectType,
                'C',
                2
        FROM #tblAllDBRoutinesTablesViews a
                INNER JOIN sysobjects b
                ON a.ObjectID = b.parent_obj
                INNER JOIN sys.sql_dependencies c
                ON b.id = c.[object_id]
                INNER JOIN #MySysdepends d
                ON c.[referenced_major_id] = d.id
                LEFT OUTER JOIN #MySysdepends x
                ON a.ObjectID = x.id
                        AND d.id = x.depid
        WHERE   d.AuxiliaryInt = 1
                AND x.id IS NULL
        
        SET @Cnt2 = @@ROWCOUNT

END -- WHILE

--===================================================================
-- Step 1 Completed
--===================================================================

-- At this point we have obtained all information from sysdepends, as well as FK relationships.
-- We now continue with text-based dependency checks.

DECLARE @CurrIdx INT
DECLARE @CurrOffset INT
DECLARE @CurrColid INT
DECLARE @CurrColText NVARCHAR(4000)
DECLARE @CurrTxtPtr BINARY(16)
DECLARE @i INT
DECLARE @CurrDataLength INT
DECLARE @CommentCounter INT
DECLARE @InComment BIT
DECLARE @tmpString NVARCHAR(280)
DECLARE @Diff INT
DECLARE @StartStr NVARCHAR(32)
DECLARE @EndStr NVARCHAR(32)
DECLARE @dbgDateTime1 DATETIME
DECLARE @dbgDateTime2 DATETIME

-- #tblTextBasedObjects holds all text-based objects of interest and their body text.
IF OBJECT_ID('tempdb..#tblTextBasedObjects') IS NOT NULL
        DROP TABLE #tblTextBasedObjects

CREATE TABLE #tblTextBasedObjects (
        ObjectID INT NOT NULL PRIMARY KEY NONCLUSTERED,
        ObjectType NVARCHAR(32) COLLATE database_default NOT NULL,
        ObjectOwnerOrSchema NVARCHAR(128) COLLATE database_default NOT NULL,
        ObjectName NVARCHAR(128) COLLATE database_default NOT NULL,
        -- ObjectText contains the CREATE statement for each text-based object.
        ObjectText NVARCHAR(MAX) COLLATE database_default,
        -- ObjectTextWithoutComments stored the CREATE statement for each object without code comments.
        ObjectTextWithoutComments NVARCHAR(MAX) COLLATE database_default)

-- We use @sSPID in the index name to avoid the case where several users
-- are running the same script on the same database and cause index name conflicts.
SET @sSPID = CAST(@@SPID AS VARCHAR(32))
EXEC('CREATE UNIQUE CLUSTERED INDEX CI_tblTextBasedObjects' + @sSPID + ' ON #tblTextBasedObjects(ObjectID, ObjectType) ')


--====================================================================
-- Step 2 Starts
--====================================================================

-- On top of the dependency found so far, we also parse the text of all
-- stored procs, functions, views, and triggers. We parse out all the comments
-- in their code, and then look for references to other objects.

IF @IncludeDependencies = 1
        OR @IncludeDependants = 1
        OR @IncludeAllDBObjects = 1
BEGIN
        -- Views, procs, and functions.
        INSERT INTO #tblTextBasedObjects (
                ObjectID,
                ObjectOwnerOrSchema,
                ObjectName,
                ObjectType)
        SELECT  ObjectID,
                ObjectOwnerOrSchema,
                ObjectName,
                ObjectType
        FROM #tblAllDBRoutinesTablesViews
        WHERE ObjectType IN ('VIEW', 'PROCEDURE', 'FUNCTION')
                AND OBJECTPROPERTY(ObjectID, 'IsMSShipped') = 0

        -- Triggers
        INSERT INTO #tblTextBasedObjects (
                ObjectID,
                ObjectOwnerOrSchema,
                ObjectName,
                ObjectType)
        SELECT  id,
                USER_NAME(uid),
                name,
                N'TRIGGER'
        FROM sysobjects a
                INNER JOIN #tblAllDBRoutinesTablesViews b
                ON a.parent_obj = b.ObjectID
        WHERE a.xtype = 'TR'
                AND OBJECTPROPERTY(a.id, 'IsMSShipped') = 0
END
ELSE -- only consider objects in #tblObjects or triggers with parent objects in #tblObjects
BEGIN
        -- Text-based objects from #tblObjects
        INSERT INTO #tblTextBasedObjects (
                ObjectID,
                ObjectOwnerOrSchema,
                ObjectName,
                ObjectType)
        SELECT  ObjectID,
                ObjectOwnerOrSchema,
                ObjectName,
                ObjectType
        FROM #tblObjects
        WHERE ObjectType IN ('VIEW', 'PROCEDURE', 'FUNCTION')

        -- Triggers that their parent objects (tables, views) are in #tblObjects.
        INSERT INTO #tblTextBasedObjects (
                ObjectID,
                ObjectOwnerOrSchema,
                ObjectName,
                ObjectType)
        SELECT  a.id,
                USER_NAME(a.uid),
                a.name,
                'TRIGGER'
        FROM sysobjects a
                INNER JOIN #tblObjects b
                ON a.parent_obj = b.ObjectID
        WHERE a.xtype = 'TR'
                AND OBJECTPROPERTY(a.id, 'IsMSShipped') = 0
END

/* debug */
-- SET @dbgDateTime1 = getdate()

-- Get the text of all text-based objects from sys.sql_modules.
UPDATE a
SET a.ObjectText = b.[definition]
FROM #tblTextBasedObjects a
        INNER JOIN sys.sql_modules b
        ON a.ObjectID = b.[object_id]

-- Do not consider encrypted objects
-- Here we use syscomments since it has the encryption info, which is
-- not available in sys.sql_modules.
DELETE a
FROM #tblTextBasedObjects a
        INNER JOIN syscomments b
        ON a.ObjectID = b.id
        WHERE b.encrypted = 1

-- The column ObjectTextWithoutComments will contain the parsed CREATE statement of each object,
-- (i.e., the CREATE statement without any comments).
UPDATE #tblTextBasedObjects
SET ObjectTextWithoutComments = ObjectText


-- In this section we parse and exclude the comments in the CREATE
-- statement of all text-based objects. This is done in #tblTextBasedObjects
-- and has no effect on the underlying database objects.
SELECT @CurrObjectID = MIN(ObjectID)
FROM #tblTextBasedObjects

SELECT  @CurrDataLength = ISNULL(DATALENGTH(ObjectText), 0)
FROM #tblTextBasedObjects
WHERE ObjectID = @CurrObjectID

WHILE @CurrObjectID IS NOT NULL
BEGIN
        -- First, take out all comments of the type /* ... */
        SELECT  @i = PATINDEX('%/*%', ObjectTextWithoutComments)
        FROM #tblTextBasedObjects
        WHERE ObjectID = @CurrObjectID
        
        SET @StopLoop = 0

        -- Inner loop is used to take out all comments or the type /* ... */
        -- and not only the first instance of such comment. 
        WHILE @i > 0 AND @StopLoop = 0
        BEGIN
                SET @Cnt = @i - 1
                SET @i = @i + 1 -- takes care of the case /*/ 
                SET @CommentCounter = 1
                SET @InComment = 1

                -- This loop searches for the closing pattern of the comment "*/",
                -- and also considers nested comments.
                WHILE @InComment = 1 AND @StopLoop = 0
                BEGIN
                        SET @i = @i + 1

                        SELECT @tmpString = SUBSTRING(ObjectTextWithoutComments, @i, 2)
                        FROM #tblTextBasedObjects
                        WHERE ObjectID = @CurrObjectID

                        IF @tmpString = N'/*'
                        BEGIN
                                SET @CommentCounter = @CommentCounter + 1
                                SET @i = @i + 1
                        END

                        IF @tmpString = N'*/'
                        BEGIN
                                SET @CommentCounter = @CommentCounter - 1
                                
                                -- This takes care of the scenario */*/
                                IF @CommentCounter > 0
                                        SET @i = @i + 1
                        END

                        IF @CommentCounter = 0
                                SET @InComment = 0

                        IF @i = @CurrDataLength
                                SET @StopLoop = 1
                END
                
                SET @Diff = @i - @Cnt + 1
                SET @tmpString = N''

                -- Delete the comment from the CREATE statement stored in #tblTextBasedObjects
                UPDATE #tblTextBasedObjects
                SET ObjectTextWithoutComments = SUBSTRING(ObjectTextWithoutComments, 1, @Cnt) + SUBSTRING(ObjectTextWithoutComments, @Cnt + @Diff + 1, @CurrDataLength) -- @CurrTxtPtr @Cnt @Diff @tmpString
                WHERE ObjectID = @CurrObjectID


                SELECT  @i = PATINDEX('%/*%', ObjectTextWithoutComments),
                        @CurrDataLength = (ISNULL(DATALENGTH(ObjectTextWithoutComments), 0))/2
                FROM #tblTextBasedObjects
                WHERE ObjectID = @CurrObjectID
        END

        -- Secondly, we parse out all comments that begin with --
        SELECT  @i = PATINDEX('%--%', ObjectTextWithoutComments),
                @CurrDataLength = (ISNULL(DATALENGTH(ObjectTextWithoutComments), 0))/2
        FROM #tblTextBasedObjects
        WHERE ObjectID = @CurrObjectID
        
        SET @StopLoop = 0

        -- Inner loop is used to take out all comments or the type --
        -- and not only the first instance of such comment.
        WHILE @i > 0 AND @StopLoop = 0
        BEGIN
                SET @Cnt = @i - 1
                SET @CommentCounter = 1
                SET @InComment = 1

                SELECT  @Cnt1 = PATINDEX('%' + CHAR(10) + '%', SUBSTRING(ObjectTextWithoutComments, @i, @CurrDataLength)),
                        @Cnt2 = PATINDEX('%' + CHAR(13) + '%', SUBSTRING(ObjectTextWithoutComments, @i, @CurrDataLength)),
                        @CurrDataLength = (ISNULL(DATALENGTH(ObjectTextWithoutComments), 0))/2
                FROM #tblTextBasedObjects
                WHERE ObjectID = @CurrObjectID

                IF @Cnt1 > @Cnt2
                BEGIN
                        IF @Cnt2 > 0
                                -- CHAR(13) exits before CHAR(10)
                                SET @Diff = @Cnt2
                        ELSE
                                -- CHAR(10) exists and CHAR(13) does not
                                SET @Diff = @Cnt1
                END
                ELSE
                BEGIN
                        IF @Cnt2 > @Cnt1
                                IF @Cnt1 > 0
                                        -- CHAR(10) exits before CHAR(13)
                                        SET @Diff = @Cnt1
                                ELSE
                                        -- CHAR(13) exists and CHAR(10) does not
                                        SET @Diff = @Cnt2
                END
                                
                IF @Cnt1 = 0 AND @Cnt2 = 0
                        SELECT @Diff = @CurrDataLength - @Cnt

                SET @tmpString = N''

                -- Delete the comment from the CREATE statement stored in #tblTextBasedObjects
                -- UPDATETEXT #tblTextBasedObjects.ObjectTextWithoutComments @CurrTxtPtr @Cnt @Diff @tmpString
                UPDATE #tblTextBasedObjects
                SET ObjectTextWithoutComments = SUBSTRING(ObjectTextWithoutComments, 1, @Cnt) + SUBSTRING(ObjectTextWithoutComments, @Cnt + @Diff + 1, @CurrDataLength) -- @CurrTxtPtr @Cnt @Diff @tmpString
                WHERE ObjectID = @CurrObjectID
                        
                SELECT  @i = PATINDEX('%--%', ObjectTextWithoutComments)
                FROM #tblTextBasedObjects
                WHERE ObjectID = @CurrObjectID
        END

        SELECT @CurrObjectID = MIN(ObjectID)
        FROM #tblTextBasedObjects
        WHERE ObjectID > @CurrObjectID
        
        SELECT  @CurrDataLength = ISNULL(DATALENGTH(ObjectText), 0)
        FROM #tblTextBasedObjects
        WHERE ObjectID = @CurrObjectID
END

--====================================================================
-- Step 2 Completed
--====================================================================


/* debug */
-- SET @dbgDateTime2 = getdate()
-- PRINT('Uncommenting all text took ' + CAST(DATEDIFF(SECOND, @dbgDateTime1, @dbgDateTime2) AS VARCHAR(32)) + ' seconds')


--====================================================================
-- Step 3 Starts
--====================================================================

-- Now that we have the text (without comments) of all text-based objects
-- and we need to conclude dependencies.

-- Characters that can appear before a table/view name
-- Note: The characters that can appear before a proc/function are a subset of the below.
-- CHAR(9)  TAB
-- CHAR(10) LF
-- CHAR(13) CR
-- CHAR(32) ' ' (space)
-- CHAR(33) '!' (not less than) e.g., WHERE TableName.Col1 !TableName.Col2
-- CHAR(34) '"' (quoted identifier)
-- CHAR(37) '%' (modulo) e.g., WHERE TableName.Col1%TableName.Col2 = 1
-- CHAR(38) '&' (bitwise and)
-- CHAR(39) ''' (in string) - OMITTED!
-- CHAR(40) '('
-- CHAR(41) ')'
-- CHAR(42) '*'
-- CHAR(43) '+'
-- CHAR(44) ','
-- CHAR(45) '-'
-- CHAR(46) '.'
-- CHAR(47) '/'
-- CHAR(59) ';'
-- CHAR(60) '<'
-- CHAR(61) '='
-- CHAR(62) '>'
-- CHAR(91) '[' - treated separately since ']' must follow after the object name.
-- CHAR(94) '^'
-- CHAR(124) '|'
-- CHAR(124) '~'

-- Characters that can appear after a table/view name
-- Note: The characters that can appear after a proc/function are a subset of the below.
-- CHAR(9)  TAB
-- CHAR(10) LF
-- CHAR(13) CR
-- CHAR(32) ' '
-- CHAR(33) '!'
-- CHAR(34) '"'
-- CHAR(37) '%'
-- CHAR(38) '&'
-- CHAR(39) ''' (in string) - OMITTED!
-- CHAR(40) '('
-- CHAR(41) ')'
-- CHAR(42) '*'
-- CHAR(43) '+'
-- CHAR(44) ','
-- CHAR(45) '-'
-- CHAR(46) '.'
-- CHAR(47) '/'
-- CHAR(58) ':'
-- CHAR(59) ';'
-- CHAR(60) '<'
-- CHAR(61) '='
-- CHAR(62) '>'
-- CHAR(93) ']' - treated separately due to T-SQL limitations
-- CHAR(94) '^'
-- CHAR(124) '|'
-- CHAR(126) '~'

SET @StartStr = N'%[' + CHAR(9) + CHAR(10) + CHAR(13) + CHAR(32) + CHAR(33) + CHAR(34)
                + CHAR(37) + CHAR(38) + CHAR(40) + CHAR(41) + CHAR(42)
                + CHAR(43) + CHAR(44) + CHAR(45) + CHAR(46) + CHAR(47) + CHAR(58) + CHAR(59)
                + CHAR(60) + CHAR(61) + CHAR(62) + CHAR(94)
                + CHAR(124) + CHAR(126) + N']'

-- HEADS UP! CHAR(93) ']' cannot be used in [] when searching text strings using the LIKE clause
-- and requires special treatment. It requires to stand alone, e.g., LIKE '%ObjectName]%'.
-- We only look for CHAR(93) ']' when the object is prepended with CHAR(91) '['
-- and CHAR(91) and CHAR(93) are handled separately.
SET @EndStr = N'[' + CHAR(9) + CHAR(10) + CHAR(13) + CHAR(32) + CHAR(33) + CHAR(34)
                + CHAR(37) + CHAR(38) + CHAR(40) + CHAR(41) + CHAR(42)
                + CHAR(43) + CHAR(44) + CHAR(45) + CHAR(46) + CHAR(47) + CHAR(58) + CHAR(59)
                + CHAR(60) + CHAR(61) + CHAR(62) + CHAR(94)
                + CHAR(124) + CHAR(126) + N']%'


-- Populate the text-search criteria for each object.
-- If an object name contains ' (single upper quote) or a space, then it must
-- be bounded by quotes (i.e., [] or "") in the SQL code. The search criteria for these objects
-- are therefore:
-- '[[]' + ObjectName + ']'
-- '"' + ObjectName + '"'
-- In all other cases, we search for the two patterns:
-- @StartStr + ObjectName + @EndStr
-- '[[]' + ObjectName + ']'
UPDATE a
SET a.ObjectNameForLikeSearches1 = CASE
        WHEN a.ObjectName LIKE N'%''%' OR a.ObjectName LIKE N'% %' THEN N'%[[]' + a.ObjectName + ']%'
        ELSE @StartStr + a.ObjectName + @EndStr
        END,
    a.ObjectNameForLikeSearches2 = CASE
        WHEN a.ObjectName LIKE N'%''%' OR a.ObjectName LIKE N'% %' THEN N'%"' + a.ObjectName + '"%'
        ELSE N'%[[]' + a.ObjectName + ']%' -- note that quoted idents are already handled by the preivous case
        END,
    a.ObjectNameForLikeSearches3 = CASE
        WHEN b.name IS NOT NULL AND (b.name LIKE N'%''%' OR b.name LIKE N'% %') THEN N'%[[]' + a.ObjectName + ']%'
        WHEN b.name IS NULL THEN NULL
        ELSE @StartStr + a.ObjectName + @EndStr
        END,
    a.ObjectNameForLikeSearches4 = CASE
        WHEN b.name IS NOT NULL AND (b.name LIKE N'%''%' OR b.name LIKE N'% %') THEN N'%"' + a.ObjectName + '"%'
        WHEN b.name IS NULL THEN NULL
        ELSE N'%[[]' + a.ObjectName + ']%' -- note that quoted idents are already handled by the preivous case
        END
FROM #tblObjects a
        LEFT OUTER JOIN sys.synonyms b
        ON a.ObjectID = b.[object_id]

UPDATE a
SET a.ObjectNameForLikeSearches1 = CASE
        WHEN a.ObjectName LIKE N'%''%' OR a.ObjectName LIKE N'% %' THEN N'%[[]' + a.ObjectName + ']%'
        ELSE @StartStr + a.ObjectName + @EndStr
        END,
    a.ObjectNameForLikeSearches2 = CASE
        WHEN a.ObjectName LIKE N'%''%' OR a.ObjectName LIKE N'% %' THEN N'%"' + a.ObjectName + '"%'
        ELSE N'%[[]' + a.ObjectName + ']%' -- note that quoted idents are already handled by the preivous case
        END,
    a.ObjectNameForLikeSearches3 = CASE
        WHEN b.name IS NOT NULL AND (b.name LIKE N'%''%' OR b.name LIKE N'% %') THEN N'%[[]' + a.ObjectName + ']%'
        WHEN b.name IS NULL THEN NULL
        ELSE @StartStr + a.ObjectName + @EndStr
        END,
    a.ObjectNameForLikeSearches4 = CASE
        WHEN b.name IS NOT NULL AND (b.name LIKE N'%''%' OR b.name LIKE N'% %') THEN N'%"' + a.ObjectName + '"%'
        WHEN b.name IS NULL THEN NULL
        ELSE N'%[[]' + a.ObjectName + ']%' -- note that quoted idents are already handled by the preivous case
        END
FROM #tblAllDBRoutinesTablesViews a
        LEFT OUTER JOIN sys.synonyms b
        ON a.ObjectID = b.[object_id]



-- We now check for dependencies and dependants based on text-searches.
-- Here, we only perform the relevant searches since the LIKE operations
-- below are very costly and slow.

-- Note: An update to the search string column in #MySysdepends
-- i.e., ObjectNameForLikeSearches1 and ObjectNameForLikeSearches2, 3, 4, occurs only as needed below.


-- 1) Get all dependencies.
IF @IncludeDependencies = 1 OR @IncludeAllDBObjects = 1
BEGIN
        /* debug */
        -- SET @dbgDateTime1 = getdate()

        -- 1.1. Check direct dependency between objects in #tblObjects and those in #tblAllDBRoutinesTablesViews,
        -- based on text-searches and code references. Child-dependencies are considered below.
        -- Note: The WHILE only needs to consider items with AuxiliaryInt = 1,
        -- to minimize the amount of LIKE operations, which are very costly.
        INSERT INTO #MySysdepends (
                id,
                depid,
                idObjectOwnerOrSchema,
                idObjectName,
                idObjectType,
                depidObjectOwnerOrSchema,
                depidObjectName,
                depidObjectType,
                depType,
                AuxiliaryInt)
        SELECT DISTINCT a.ObjectID,
                c.ObjectID,
                a.ObjectOwnerOrSchema,
                a.ObjectName,
                a.ObjectType,
                c.ObjectOwnerOrSchema,
                c.ObjectName,
                c.ObjectType,
                'S', -- direct dependency found in text-based searches
                2
        FROM #tblObjects a
                INNER JOIN #tblTextBasedObjects b
                -- Text of object in #tblObjects that contains a reference to other objects.
                ON a.ObjectID = b.ObjectID
                        AND b.ObjectType <> 'TRIGGER'
                -- The reference can be to any object in the database.
                INNER JOIN #tblAllDBRoutinesTablesViews c
                ON a.ObjectID <> c.ObjectID -- ignore self-dependency since it will cause another loop
                LEFT OUTER JOIN #MySysdepends x
                ON a.ObjectID = x.id
                        AND c.ObjectID = x.depid
        WHERE   x.id IS NULL
                AND (b.ObjectTextWithoutComments LIKE c.ObjectNameForLikeSearches1
                        OR b.ObjectTextWithoutComments LIKE c.ObjectNameForLikeSearches2
                        OR b.ObjectTextWithoutComments LIKE c.ObjectNameForLikeSearches3
                        OR b.ObjectTextWithoutComments LIKE c.ObjectNameForLikeSearches4)

        -- 1.2. Child-parent object dependencies: Check tables in #tblObjects 
        -- with triggers in #tblTextBasedObjects that depend on other objects in #tblAllDBRoutinesTablesViews.
        -- Note: We do not need to consider the case where objects in #tblObjects
        -- depend on children of other objects, since that is never possible.
        INSERT INTO #MySysdepends (
                id,
                depid,
                idObjectOwnerOrSchema,
                idObjectName,
                idObjectType,
                depidObjectOwnerOrSchema,
                depidObjectName,
                depidObjectType,
                depType,
                AuxiliaryInt)
        SELECT DISTINCT a.ObjectID,
                d.ObjectID,
                a.ObjectOwnerOrSchema,
                a.ObjectName,
                a.ObjectType,
                d.ObjectOwnerOrSchema,
                d.ObjectName,
                d.ObjectType,
                'T', -- child-object dependency found in text-based searches
                2
        FROM #tblObjects a
                INNER JOIN sysobjects b
                ON a.ObjectID = b.parent_obj
                -- Only consider text of children of objects in #tblObjects.
                INNER JOIN #tblTextBasedObjects c
                ON b.id = c.ObjectID
                        AND c.ObjectType = 'TRIGGER'
                INNER JOIN #tblAllDBRoutinesTablesViews d
                ON a.ObjectID <> d.ObjectID -- ignore self-dependency since it will cause another loop
                LEFT OUTER JOIN #MySysdepends x
                ON a.ObjectID = x.id
                        AND d.ObjectID = x.depid
        WHERE   x.id IS NULL
                AND (c.ObjectTextWithoutComments LIKE d.ObjectNameForLikeSearches1
                        OR c.ObjectTextWithoutComments LIKE d.ObjectNameForLikeSearches2
                        OR c.ObjectTextWithoutComments LIKE d.ObjectNameForLikeSearches3
                        OR c.ObjectTextWithoutComments LIKE d.ObjectNameForLikeSearches4)

        
        /* debug */
        -- SET @dbgDateTime2 = getdate()
        -- PRINT('First round of text-based dependency took ' + CAST(DATEDIFF(SECOND, @dbgDateTime1, @dbgDateTime2) AS VARCHAR(32)) + ' seconds')

        SET @Cnt1 = 1
        SET @Cnt2 = 1

        -- Recursive dependency checks- find dependencies for all objects found just now above,
        -- to get objects on which the new items depend on.
        WHILE @Cnt1 > 0 OR @Cnt2 > 0
        BEGIN
                /* debug */
                -- SET @dbgDateTime1 = getdate()
                
                UPDATE #MySysdepends
                SET AuxiliaryInt = AuxiliaryInt - 1

                -- Dependency on routines, functions, views.
                -- The WHILE only needs to consider items with AuxiliaryInt = 1.
                INSERT INTO #MySysdepends (
                        id,
                        depid,
                        idObjectOwnerOrSchema,
                        idObjectName,
                        idObjectType,
                        depidObjectOwnerOrSchema,
                        depidObjectName,
                        depidObjectType,
                        depType,
                        AuxiliaryInt)
                SELECT DISTINCT a.depid,
                        c.ObjectID,
                        a.depidObjectOwnerOrSchema,
                        a.depidObjectName,
                        a.depidObjectType,
                        c.ObjectOwnerOrSchema,
                        c.ObjectName,
                        c.ObjectType,
                        'S', -- direct dependency found in text-based searches
                        2
                FROM #MySysdepends a
                        INNER JOIN #tblTextBasedObjects b
                        -- Text of object in #tblObjects that contains a reference to other objects.
                        ON a.AuxiliaryInt = 1
                                AND a.depid = b.ObjectID
                                AND b.ObjectType <> 'TRIGGER'
                        -- The reference can be to any object in the database.
                        INNER JOIN #tblAllDBRoutinesTablesViews c
                        ON a.depid <> c.ObjectID -- ignore self-dependency since it will cause another loop
                        LEFT OUTER JOIN #MySysdepends x
                        ON a.depid = x.id
                                AND c.ObjectID = x.depid
                WHERE   x.id IS NULL
                        AND (b.ObjectTextWithoutComments LIKE c.ObjectNameForLikeSearches1
                                OR b.ObjectTextWithoutComments LIKE c.ObjectNameForLikeSearches2
                                OR b.ObjectTextWithoutComments LIKE c.ObjectNameForLikeSearches3
                                OR b.ObjectTextWithoutComments LIKE c.ObjectNameForLikeSearches4)

                
                SET @Cnt1 = @@ROWCOUNT
        
                -- Include child-parent object dependencies:
                -- Children of objects in #tblObjects depend on other objects in their text.
                -- Note: We do not need to consider the case where objects in #tblObjects
                -- depend on children of other objects, since that is never possible.
                INSERT INTO #MySysdepends (
                        id,
                        depid,
                        idObjectOwnerOrSchema,
                        idObjectName,
                        idObjectType,
                        depidObjectOwnerOrSchema,
                        depidObjectName,
                        depidObjectType,
                        depType,
                        AuxiliaryInt)
                SELECT DISTINCT a.depid,
                        d.ObjectID,
                        a.depidObjectOwnerOrSchema,
                        a.depidObjectName,
                        a.depidObjectType,
                        d.ObjectOwnerOrSchema,
                        d.ObjectName,
                        d.ObjectType,
                        'T', -- child-object dependency found in text-based searches
                        2
                FROM #MySysdepends a
                        INNER JOIN sysobjects b
                        ON a.AuxiliaryInt = 1
                                AND a.depid = b.parent_obj
                        -- Only consider text of children of objects in #tblObjects.
                        INNER JOIN #tblTextBasedObjects c
                        ON b.id = c.ObjectID
                                AND c.ObjectType = 'TRIGGER'
                        INNER JOIN #tblAllDBRoutinesTablesViews d
                        ON a.depid <> d.ObjectID -- ignore self-dependency since it will cause another loop
                        LEFT OUTER JOIN #MySysdepends x
                        ON a.depid = x.id
                                AND d.ObjectID = x.depid
                WHERE   x.id IS NULL
                        AND (c.ObjectTextWithoutComments LIKE d.ObjectNameForLikeSearches1
                                OR c.ObjectTextWithoutComments LIKE d.ObjectNameForLikeSearches2
                                OR c.ObjectTextWithoutComments LIKE d.ObjectNameForLikeSearches3
                                OR c.ObjectTextWithoutComments LIKE d.ObjectNameForLikeSearches4)
                
                SET @Cnt2 = @@ROWCOUNT

                /* debug */
                -- SET @dbgDateTime2 = getdate()
                -- PRINT('In-loop of text-based dependency took ' + CAST(DATEDIFF(SECOND, @dbgDateTime1, @dbgDateTime2) AS VARCHAR(32)) + ' seconds')
        
        END -- WHILE
END -- IF @IncludeDependencies = 1 OR @IncludeAllDBObjects = 1


-- 2) Get all dependants - perform text searches to see if any objects depend on items in #tblObjects.
IF @IncludeDependants = 1 OR @IncludeAllDBObjects = 1
BEGIN
        /* debug */
        -- SET @dbgDateTime1 = getdate()

        INSERT INTO #MySysdepends (
                id,
                depid,
                idObjectOwnerOrSchema,
                idObjectName,
                idObjectType,
                depidObjectOwnerOrSchema,
                depidObjectName,
                depidObjectType,
                depType,
                AuxiliaryInt)
        SELECT DISTINCT a.ObjectID,
                c.ObjectID,
                a.ObjectOwnerOrSchema,
                a.ObjectName,
                a.ObjectType,
                c.ObjectOwnerOrSchema,
                c.ObjectName,
                c.ObjectType,
                'S', -- direct dependency found in text-based searches
                2
        FROM #tblAllDBRoutinesTablesViews a
                INNER JOIN #tblTextBasedObjects b
                -- Text of object that are not in #tblObjects contains a reference to objects in #tblObjects.
                ON a.ObjectID = b.ObjectID
                        AND b.ObjectType <> 'TRIGGER'
                -- The reference can be to objects in #tblObjects.
                INNER JOIN #tblObjects c
                ON a.ObjectID <> c.ObjectID -- ignore self-dependency since it will cause another loop
                LEFT OUTER JOIN #MySysdepends x
                ON a.ObjectID = x.id
                        AND c.ObjectID = x.depid
        WHERE   x.id IS NULL
                AND (b.ObjectTextWithoutComments LIKE c.ObjectNameForLikeSearches1
                        OR b.ObjectTextWithoutComments LIKE c.ObjectNameForLikeSearches2
                        OR b.ObjectTextWithoutComments LIKE c.ObjectNameForLikeSearches3
                        OR b.ObjectTextWithoutComments LIKE c.ObjectNameForLikeSearches4)
        
        -- Include child-parent object dependencies.
        -- Children of objects that are not in #tblObjects depend on objects in #tblObjects via their text.
        -- Note: We do not need to consider the case where objects that are not in #tblObjects
        -- depend on children of objects in #tblObjects, since that is never possible.
        INSERT INTO #MySysdepends (
                id,
                depid,
                idObjectOwnerOrSchema,
                idObjectName,
                idObjectType,
                depidObjectOwnerOrSchema,
                depidObjectName,
                depidObjectType,
                depType,
                AuxiliaryInt)
        SELECT DISTINCT a.ObjectID,
                d.ObjectID,
                a.ObjectOwnerOrSchema,
                a.ObjectName,
                a.ObjectType,
                d.ObjectOwnerOrSchema,
                d.ObjectName,
                d.ObjectType,
                'T', -- child-object dependency found in text-based searches
                2
        FROM #tblAllDBRoutinesTablesViews a
                INNER JOIN sysobjects b
                ON a.ObjectID = b.parent_obj
                -- Only consider text of children of objects in #tblAllDBRoutinesTablesViews.
                INNER JOIN #tblTextBasedObjects c
                ON b.id = c.ObjectID
                        AND c.ObjectType = 'TRIGGER'
                INNER JOIN #tblObjects d
                ON a.ObjectID <> d.ObjectID -- ignore self-dependency since it will cause another loop
                LEFT OUTER JOIN #MySysdepends x
                ON a.ObjectID = x.id
                        AND d.ObjectID = x.depid
        WHERE   x.id IS NULL
                AND (c.ObjectTextWithoutComments LIKE d.ObjectNameForLikeSearches1
                        OR c.ObjectTextWithoutComments LIKE d.ObjectNameForLikeSearches2
                        OR c.ObjectTextWithoutComments LIKE d.ObjectNameForLikeSearches3
                        OR c.ObjectTextWithoutComments LIKE d.ObjectNameForLikeSearches4)


        -- Update all search strings in #MySysdepends.
        UPDATE a
        SET a.idObjectNameForLikeSearches1 = CASE
                WHEN a.idObjectName LIKE N'%''%' OR a.idObjectName LIKE N'% %' THEN N'%[[]' + a.idObjectName + ']%'
                ELSE @StartStr + a.idObjectName + @EndStr
                END,
            a.idObjectNameForLikeSearches2 = CASE
                WHEN a.idObjectName LIKE N'%''%' OR a.idObjectName LIKE N'% %' THEN N'%"' + a.idObjectName + '"%'
                ELSE N'%[[]' + a.idObjectName + ']%' -- note that quoted idents are already handled by the preivous case
                END,
            a.idObjectNameForLikeSearches3 = CASE
                WHEN b.name IS NOT NULL AND (b.name LIKE N'%''%' OR b.name LIKE N'% %') THEN N'%[[]' + a.idObjectName + ']%'
                WHEN b.name IS NULL THEN NULL
                ELSE @StartStr + a.idObjectName + @EndStr
                END,
            a.idObjectNameForLikeSearches4 = CASE
                WHEN b.name IS NOT NULL AND (b.name LIKE N'%''%' OR b.name LIKE N'% %') THEN N'%"' + a.idObjectName + '"%'
                WHEN b.name IS NULL THEN NULL
                ELSE N'%[[]' + a.idObjectName + ']%' -- note that quoted idents are already handled by the preivous case
                END,
            a.depidObjectNameForLikeSearches1 = CASE
                WHEN a.depidObjectName LIKE N'%''%' OR a.depidObjectName LIKE N'% %' THEN N'%[[]' + a.depidObjectName + ']%'
                ELSE @StartStr + a.depidObjectName + @EndStr
                END,
            a.depidObjectNameForLikeSearches2 = CASE
                WHEN a.depidObjectName LIKE N'%''%' OR a.depidObjectName LIKE N'% %' THEN N'%"' + a.depidObjectName + '"%'
                ELSE N'%[[]' + a.depidObjectName + ']%' -- note that quoted idents are already handled by the preivous case
                END,
            a.depidObjectNameForLikeSearches3 = CASE
                WHEN c.name IS NOT NULL AND (c.name LIKE N'%''%' OR c.name LIKE N'% %') THEN N'%[[]' + a.depidObjectName + ']%'
                WHEN c.name IS NULL THEN NULL
                ELSE @StartStr + a.depidObjectName + @EndStr
                END,
            a.depidObjectNameForLikeSearches4 = CASE
                WHEN c.name IS NOT NULL AND (c.name LIKE N'%''%' OR c.name LIKE N'% %') THEN N'%"' + a.depidObjectName + '"%'
                WHEN c.name IS NULL THEN NULL
                ELSE N'%[[]' + a.depidObjectName + ']%' -- note that quoted idents are already handled by the preivous case
                END
        FROM #MySysdepends a
                LEFT OUTER JOIN sys.synonyms b
                ON a.id = b.[object_id]
                LEFT OUTER JOIN sys.synonyms c
                ON a.depid = c.[object_id]

        
        /* debug */
        -- SET @dbgDateTime2 = getdate()
        -- PRINT('First round of text-based dependants took ' + CAST(DATEDIFF(SECOND, @dbgDateTime1, @dbgDateTime2) AS VARCHAR(32)) + ' seconds')

        SET @Cnt1 = 1
        SET @Cnt2 = 1
        
        WHILE @Cnt1 > 0 OR @Cnt2 > 0
        BEGIN
                /* debug */
                -- SET @dbgDateTime1 = getdate()

                UPDATE #MySysdepends
                SET AuxiliaryInt = AuxiliaryInt - 1

                -- Dependants that are views, procs, functions.
                INSERT INTO #MySysdepends (
                        id,
                        depid,
                        idObjectOwnerOrSchema,
                        idObjectName,
                        idObjectType,
                        depidObjectOwnerOrSchema,
                        depidObjectName,
                        depidObjectType,
                        depType,
                        AuxiliaryInt)
                SELECT DISTINCT a.ObjectID,
                        c.id,
                        a.ObjectOwnerOrSchema,
                        a.ObjectName,
                        a.ObjectType,
                        c.idObjectOwnerOrSchema,
                        c.idObjectName,
                        c.idObjectType,
                        'S', -- direct dependency found in text-based searches
                        2
                FROM #tblAllDBRoutinesTablesViews a
                        INNER JOIN #tblTextBasedObjects b
                        -- Text of object that are not in #tblObjects contains a reference to objects in #tblObjects.
                        ON a.ObjectID = b.ObjectID
                                AND b.ObjectType <> 'TRIGGER'
                        -- The reference can be to objects in #tblObjects.
                        INNER JOIN #MySysdepends c
                        ON c.AuxiliaryInt = 1
                                AND a.ObjectID <> c.id -- ignore self-dependency since it will cause another loop
                        LEFT OUTER JOIN #MySysdepends x
                        ON a.ObjectID = x.id
                                AND c.id = x.depid
                WHERE   x.id IS NULL
                        AND (b.ObjectTextWithoutComments LIKE c.idObjectNameForLikeSearches1
                                OR b.ObjectTextWithoutComments LIKE c.idObjectNameForLikeSearches2
                                OR b.ObjectTextWithoutComments LIKE c.idObjectNameForLikeSearches3
                                OR b.ObjectTextWithoutComments LIKE c.idObjectNameForLikeSearches4)
                
                SET @Cnt1 = @@ROWCOUNT
        
                -- Include child-parent object dependencies.
                -- Children of objects that are not in #tblObjects depend on objects in #tblObjects via their text.
                -- Note: We do not need to consider the case where objects that are not in #tblObjects
                -- depend on children of objects in #tblObjects, since that is never possible.
                INSERT INTO #MySysdepends (
                        id,
                        depid,
                        idObjectOwnerOrSchema,
                        idObjectName,
                        idObjectType,
                        depidObjectOwnerOrSchema,
                        depidObjectName,
                        depidObjectType,
                        depType,
                        AuxiliaryInt)
                SELECT DISTINCT a.ObjectID,
                        d.id,
                        a.ObjectOwnerOrSchema,
                        a.ObjectName,
                        a.ObjectType,
                        d.idObjectOwnerOrSchema,
                        d.idObjectName,
                        d.idObjectType,
                        'T', -- child-object dependency found in text-based searches
                        2
                FROM #tblAllDBRoutinesTablesViews a
                        INNER JOIN sysobjects b
                        ON a.ObjectID = b.parent_obj
                        -- Only consider text of children of objects in #tblAllDBRoutinesTablesViews.
                        INNER JOIN #tblTextBasedObjects c
                        ON b.id = c.ObjectID
                                AND c.ObjectType = 'TRIGGER'
                        INNER JOIN #MySysdepends d
                        ON d.AuxiliaryInt = 1
                                AND a.ObjectID <> d.id -- ignore self-dependency since it will cause another loop
                        LEFT OUTER JOIN #MySysdepends x
                        ON a.ObjectID = x.id
                                AND d.id = x.depid
                WHERE   x.id IS NULL
                        AND (c.ObjectTextWithoutComments LIKE d.idObjectNameForLikeSearches1
                                OR c.ObjectTextWithoutComments LIKE d.idObjectNameForLikeSearches2
                                OR c.ObjectTextWithoutComments LIKE d.idObjectNameForLikeSearches3
                                OR c.ObjectTextWithoutComments LIKE d.idObjectNameForLikeSearches4)
                
                SET @Cnt2 = @@ROWCOUNT

                -- Update all search strings in #MySysdepends.
                UPDATE a
                SET a.idObjectNameForLikeSearches1 = CASE
                        WHEN a.idObjectName LIKE N'%''%' OR a.idObjectName LIKE N'% %' THEN N'%[[]' + a.idObjectName + ']%'
                        ELSE @StartStr + a.idObjectName + @EndStr
                        END,
                    a.idObjectNameForLikeSearches2 = CASE
                        WHEN a.idObjectName LIKE N'%''%' OR a.idObjectName LIKE N'% %' THEN N'%"' + a.idObjectName + '"%'
                        ELSE N'%[[]' + a.idObjectName + ']%' -- note that quoted idents are already handled by the preivous case
                        END,
                    a.idObjectNameForLikeSearches3 = CASE
                        WHEN b.name IS NOT NULL AND (b.name LIKE N'%''%' OR b.name LIKE N'% %') THEN N'%[[]' + a.idObjectName + ']%'
                        WHEN b.name IS NULL THEN NULL
                        ELSE @StartStr + a.idObjectName + @EndStr
                        END,
                    a.idObjectNameForLikeSearches4 = CASE
                        WHEN b.name IS NOT NULL AND (b.name LIKE N'%''%' OR b.name LIKE N'% %') THEN N'%"' + a.idObjectName + '"%'
                        WHEN b.name IS NULL THEN NULL
                        ELSE N'%[[]' + a.idObjectName + ']%' -- note that quoted idents are already handled by the preivous case
                        END,
                    a.depidObjectNameForLikeSearches1 = CASE
                        WHEN a.depidObjectName LIKE N'%''%' OR a.depidObjectName LIKE N'% %' THEN N'%[[]' + a.depidObjectName + ']%'
                        ELSE @StartStr + a.depidObjectName + @EndStr
                        END,
                    a.depidObjectNameForLikeSearches2 = CASE
                        WHEN a.depidObjectName LIKE N'%''%' OR a.depidObjectName LIKE N'% %' THEN N'%"' + a.depidObjectName + '"%'
                        ELSE N'%[[]' + a.depidObjectName + ']%' -- note that quoted idents are already handled by the preivous case
                        END,
                    a.depidObjectNameForLikeSearches3 = CASE
                        WHEN c.name IS NOT NULL AND (c.name LIKE N'%''%' OR c.name LIKE N'% %') THEN N'%[[]' + a.depidObjectName + ']%'
                        WHEN c.name IS NULL THEN NULL
                        ELSE @StartStr + a.depidObjectName + @EndStr
                        END,
                    a.depidObjectNameForLikeSearches4 = CASE
                        WHEN c.name IS NOT NULL AND (c.name LIKE N'%''%' OR c.name LIKE N'% %') THEN N'%"' + a.depidObjectName + '"%'
                        WHEN c.name IS NULL THEN NULL
                        ELSE N'%[[]' + a.depidObjectName + ']%' -- note that quoted idents are already handled by the preivous case
                        END
                FROM #MySysdepends a
                        LEFT OUTER JOIN sys.synonyms b
                        ON a.id = b.[object_id]
                        LEFT OUTER JOIN sys.synonyms c
                        ON a.depid = c.[object_id]
                
        
                /* debug */
                -- SET @dbgDateTime2 = getdate()
                -- PRINT('In-loop of text-based dependants took ' + CAST(DATEDIFF(SECOND, @dbgDateTime1, @dbgDateTime2) AS VARCHAR(32)) + ' seconds')
        
        END -- WHILE
END -- IF @IncludeDependants = 1 OR @IncludeAllDBObjects = 1


-- 3) If we only need to find dependencyies between objects in #tblRequestedObjects,
--    as specified by the user, then we only perform the text based searches for objects in #tblObjects.
IF @IncludeDependencies = 0 AND @IncludeDependants = 0 AND @IncludeAllDBObjects = 0
BEGIN        
        /* debug */
        -- SET @dbgDateTime1 = getdate()

        -- Dependency and dependants on routines, functions, views.
        -- Here, the code to check dependencies and dependants is identical.
        INSERT INTO #MySysdepends (
                id,
                depid,
                idObjectOwnerOrSchema,
                idObjectName,
                idObjectType,
                depidObjectOwnerOrSchema,
                depidObjectName,
                depidObjectType,
                depType,
                AuxiliaryInt) -- not important here
        SELECT DISTINCT a.ObjectID,
                c.ObjectID,
                a.ObjectOwnerOrSchema,
                a.ObjectName,
                a.ObjectType,
                c.ObjectOwnerOrSchema,
                c.ObjectName,
                c.ObjectType,
                'S', -- direct dependency found in text-based searches
                2
        FROM #tblObjects a
                INNER JOIN #tblTextBasedObjects b
                -- Text of object in #tblObjects that contains a reference to other objects.
                ON a.ObjectID = b.ObjectID
                        AND b.ObjectType <> 'TRIGGER'
                -- The reference can be to objects in the #tblObjects.
                INNER JOIN #tblObjects c
                ON a.ObjectID <> c.ObjectID -- ignore self-dependency since it will cause another loop
                LEFT OUTER JOIN #MySysdepends x
                ON a.ObjectID = x.id
                        AND c.ObjectID = x.depid
        WHERE   x.id IS NULL
                AND (b.ObjectTextWithoutComments LIKE c.ObjectNameForLikeSearches1
                        OR b.ObjectTextWithoutComments LIKE c.ObjectNameForLikeSearches2
                        OR b.ObjectTextWithoutComments LIKE c.ObjectNameForLikeSearches3
                        OR b.ObjectTextWithoutComments LIKE c.ObjectNameForLikeSearches4)



        -- Include child-parent object dependencies:
        -- Children of objects in #tblObjects depend on other objects in #tblObjects through their text.
        -- Note: We do not need to consider the case where objects in #tblObjects
        -- depend on children of other objects in #tblObjects, since that is never possible.
        INSERT INTO #MySysdepends (
                id,
                depid,
                idObjectOwnerOrSchema,
                idObjectName,
                idObjectType,
                depidObjectOwnerOrSchema,
                depidObjectName,
                depidObjectType,
                depType,
                AuxiliaryInt) -- not important here
        SELECT DISTINCT a.ObjectID,
                d.ObjectID,
                a.ObjectOwnerOrSchema,
                a.ObjectName,
                a.ObjectType,
                d.ObjectOwnerOrSchema,
                d.ObjectName,
                d.ObjectType,
                'T', -- child-object dependency found in text-based searches
                2
        FROM #tblObjects a
                INNER JOIN sysobjects b
                ON a.ObjectID = b.parent_obj
                -- Only consider text of children of objects in #tblObjects.
                INNER JOIN #tblTextBasedObjects c
                ON b.id = c.ObjectID
                        AND c.ObjectType = 'TRIGGER'
                INNER JOIN #tblObjects d
                ON a.ObjectID <> d.ObjectID -- ignore self-dependency since it will cause another loop
                LEFT OUTER JOIN #MySysdepends x
                ON a.ObjectID = x.id
                        AND d.ObjectID = x.depid
        WHERE   x.id IS NULL
                AND (c.ObjectTextWithoutComments LIKE d.ObjectNameForLikeSearches1
                        OR c.ObjectTextWithoutComments LIKE d.ObjectNameForLikeSearches2
                        OR c.ObjectTextWithoutComments LIKE d.ObjectNameForLikeSearches3
                        OR c.ObjectTextWithoutComments LIKE d.ObjectNameForLikeSearches4)

        /* debug */
        -- SET @dbgDateTime2 = getdate()
        -- PRINT('Self-dependency and dependants took ' + CAST(DATEDIFF(SECOND, @dbgDateTime1, @dbgDateTime2) AS VARCHAR(32)) + ' seconds')
END

--====================================================================
-- Step 3 Completed
--====================================================================

-- Here, #MySysdepends contains all database object dependencies and it is
-- left to return the deployment order for all database objects.

/* debug */
-- SELECT * FROM #MySysdepends


-- Populate #tblObjects to include all the dependant and depending objects
-- that were found to be relevant and recorded in #MySysdepends, yet were not
-- previously populated in #tblObjects.
IF @IncludeReplicationObjects = 0
        DELETE FROM #MySysdepends
        WHERE OBJECTPROPERTY(id, 'IsMSShipped') = 1
                OR OBJECTPROPERTY(depid, 'IsMSShipped') = 1
                OR OBJECTPROPERTY(id, 'IsReplProc') = 1
                OR OBJECTPROPERTY(depid, 'IsReplProc') = 1
ELSE
        DELETE FROM #MySysdepends
        WHERE OBJECTPROPERTY(id, 'IsMSShipped') = 1
                OR OBJECTPROPERTY(depid, 'IsMSShipped') = 1


-- Populate the relevant objects based on dependency findings.
IF @IncludeDependencies = 1 AND @IncludeAllDBObjects = 0
BEGIN
        -- Loop to populate all dependants and their dependants.
        SET @Cnt = 1
     
        WHILE @Cnt > 0
        BEGIN
                INSERT INTO #tblObjects (
                        ObjectID,
                        ObjectOwnerOrSchema,
                        ObjectName,
                        ObjectType,
                        AuxiliaryOrdering)
                SELECT  DISTINCT a.depid,
                        a.depidObjectOwnerOrSchema,
                        a.depidObjectName,
                        a.depidObjectType,
                        CASE    WHEN a.depidObjectType = 'TABLE' THEN 1
                                WHEN a.depidObjectType = 'VIEW' THEN 2
                                WHEN a.depidObjectType = 'PROCEDURE' THEN 3
                                WHEN a.depidObjectType = 'FUNCTION' THEN 4
                        END
                FROM #MySysdepends a
                        -- Get objects on which items it #tblObjects depend
                        INNER JOIN #tblObjects b
                        ON a.id = b.ObjectID
                        -- And that are not yet in #tblObjects
                        LEFT OUTER JOIN #tblObjects c
                        ON a.depid = c.ObjectID
                WHERE c.ObjectID IS NULL

                SET @Cnt = @@ROWCOUNT
        END
END

-- Populate the relevant objects based on dependants findings.
IF @IncludeDependants = 1 AND @IncludeAllDBObjects = 0
BEGIN
        -- Loop to populate all dependants and their dependants.
        SET @Cnt = 1
        
        WHILE @Cnt > 0
        BEGIN
                INSERT INTO #tblObjects (
                        ObjectID,
                        ObjectOwnerOrSchema,
                        ObjectName,
                        ObjectType,
                        AuxiliaryOrdering)
                SELECT  DISTINCT a.id,
                        a.idObjectOwnerOrSchema,
                        a.idObjectName,
                        a.idObjectType,
                        CASE    WHEN a.idObjectType = 'TABLE' THEN 1
                                WHEN a.idObjectType = 'VIEW' THEN 2
                                WHEN a.idObjectType = 'PROCEDURE' THEN 3
                                WHEN a.idObjectType = 'FUNCTION' THEN 4
                        END
                FROM #MySysdepends a
                        -- Get objects that items in #tblObjects depend on
                        INNER JOIN #tblObjects b
                        ON a.depid = b.ObjectID
                        -- And that are not yet in #tblObjects
                        LEFT OUTER JOIN #tblObjects c
                        ON a.id = c.ObjectID
                WHERE c.ObjectID IS NULL
                
                SET @Cnt = @@ROWCOUNT
        END
END


--====================================================================
-- Step 4 Starts
--====================================================================

-- #tblDependencyAndDeploymentOrder is the table that contains all objects to be considered.
-- UNLIKE #tblObjects, THE OBJECTS IN #tblDependencyAndDeploymentOrder INCLUDE THE DEPENDENCY AND DEPLOYMENT ORDER!!!
IF OBJECT_ID('tempdb..#tblDependencyAndDeploymentOrder') IS NOT NULL
        DROP TABLE #tblDependencyAndDeploymentOrder

CREATE TABLE #tblDependencyAndDeploymentOrder
        (DeploymentOrder INT IDENTITY(1, 1),
        DependencyLevel INT NOT NULL,
        ObjectID INT NOT NULL PRIMARY KEY CLUSTERED,
        ObjectOwnerOrSchema NVARCHAR(128) COLLATE database_default NOT NULL,
        ObjectName NVARCHAR(128) COLLATE database_default NOT NULL,
        QualifiedNameForObjectIDFn NVARCHAR(264) COLLATE database_default NOT NULL,
        ObjectType NVARCHAR(128) COLLATE database_default NOT NULL,
        IsEncrypted BIT NOT NULL,
        CircularDependency BIT NOT NULL)

-- We now get the order of dependency for all objects:
-- Part 1- record all objects that do not depend on other objects
--      either through direct dependency or through their child objects.
-- Part 2- loop to find and record objects that depend on previously recorded in Step 1
--      (either directly or though child objects).
-- Part 3- If any objects are not yet recorded, then these objects
--      contain circular dependency (either directly, or that their child objects
--      create a circular dependency).
--      Populate the table that warns about circular dependencies.
-- Part 4- Record objects that have circular direct (not thgouh child objects)
--      on other objects.
-- Part 5- Record all remaining objects (i.e., all objects that their child
--      objects cause circular dependency).



-- Get all objects that do not depend on any other objects (directly and via child objects)
-- or only depend on themselves (self-dependency).
-- ALL INSERTS TO #tblDependencyAndDeploymentOrder ARE ORDERED!!! FIRST BY DEPENDENCY, THEN BY OBJECTTYPE.
INSERT INTO #tblDependencyAndDeploymentOrder (
        ObjectID, 
        ObjectOwnerOrSchema, 
        ObjectName, 
        QualifiedNameForObjectIDFn,
        ObjectType,
        CircularDependency,
        IsEncrypted, 
        DependencyLevel)
SELECT  a.ObjectID,
        a.ObjectOwnerOrSchema,
        a.ObjectName,
        N'[' + REPLACE(a.ObjectOwnerOrSchema, '''', '''''') + '].[' + REPLACE(a.ObjectName, '''', '''''') + ']',
        a.ObjectType,
        0,
        0,
        0
FROM #tblObjects a
        LEFT OUTER JOIN (
                -- All routines that depend on other routines
                SELECT DISTINCT z.ObjectID
                FROM #tblObjects z
                        INNER JOIN #MySysdepends b
                        ON b.id = z.ObjectID
                        INNER JOIN #tblObjects c
                        ON b.depid = c.ObjectID
                WHERE b.id <> b.depid
        ) RS1
        ON a.ObjectID = RS1.ObjectID
WHERE RS1.ObjectID IS NULL
ORDER BY a.AuxiliaryOrdering, a.ObjectOwnerOrSchema, a.ObjectName


-- Now, drill down in the dependency hierarchy. Get all objects
-- that have a dependecy on one or more objects in #tblDependencyAndDeploymentOrder,
-- yet only depend on objects in #tblDependencyAndDeploymentOrder(!) (or have self-dependency),
-- and that have not yet been recorded in #tblDependencyAndDeploymentOrder.
-- Objects that reference themselves, as well as other routines in #tblDependencyAndDeploymentOrder,
-- are considered as well.
-- Another select is added to account for dependencies of child objects!
-- This is done in a loop, and the loop terminates when we reach the lowest level
-- in the hierarchy (i.e., when no more routines meet the listed condition).


SET @i = 0
SET @Cnt = 1

WHILE @Cnt > 0
BEGIN
        -- Analyze the next level in the hierarchy.
        SET @i = @i + 1


        -- Get all objects that reference objects that are recorded
        -- in #tblDependencyAndDeploymentOrder (can also reference themselves),
        -- and do not references objects that were not yet recorded.
        -- References include direct references, or references via child objects.
        -- This is done by as follows:
        -- RS1 conatains the objects that are not yet in #tblDependencyAndDeploymentOrder
        -- yet appear in sys.sql_dependencies and reference objects in #tblDependencyAndDeploymentOrder
        -- (and possibly have a self-reference).
        -- RS2 contains all objects that reference objects that are not yet
        -- in #tblDependencyAndDeploymentOrder (excluding self-refences).
        -- RS3 contains all objects that are not yet in #tblDependencyAndDeploymentOrder
        -- and that their child objects depend on objects that are not recorded
        -- in #tblDependencyAndDeploymentOrder (excluding self-refences).
        -- We write into #tblDependencyAndDeploymentOrder the routines in RS1, which are
        -- not in RS2.

        INSERT INTO #tblDependencyAndDeploymentOrder (
                ObjectID, 
                ObjectOwnerOrSchema, 
                ObjectName, 
                QualifiedNameForObjectIDFn,
                ObjectType, 
                CircularDependency,
                IsEncrypted, 
                DependencyLevel)
        SELECT  a.ObjectID,
                a.ObjectOwnerOrSchema,
                a.ObjectName,
                N'[' + REPLACE(a.ObjectOwnerOrSchema, '''', '''''') + '].[' + REPLACE(a.ObjectName, '''', '''''') + ']',
                a.ObjectType,
                0,
                0,
                @i
        FROM #tblObjects a
                -- Objects in #tblObjects and not in #tblDependencyAndDeploymentOrder
                -- that depend on objects in #tblDependencyAndDeploymentOrder
                INNER JOIN
                (SELECT DISTINCT c.id
                FROM #tblObjects b
                        INNER JOIN #MySysdepends c
                        ON c.id = b.ObjectID
                        INNER JOIN #tblDependencyAndDeploymentOrder d
                        ON d.ObjectID = c.depid
                        LEFT OUTER JOIN #tblDependencyAndDeploymentOrder e WITH (NOLOCK)
                        ON c.id = e.ObjectID
                WHERE e.ObjectOwnerOrSchema IS NULL) RS1
                ON RS1.id = a.ObjectID
                -- Objects in #tblObjects that depend on objects not in #tblDependencyAndDeploymentOrder
                LEFT OUTER JOIN
                (SELECT DISTINCT w.id
                FROM #tblObjects v
                        INNER JOIN #MySysdepends w
                        ON w.id = v.ObjectID
                        INNER JOIN #tblObjects x
                        ON w.depid = x.ObjectID
                        LEFT OUTER JOIN #tblDependencyAndDeploymentOrder y
                        ON y.ObjectID = w.depid
                WHERE w.id <> w.depid
                        AND y.ObjectOwnerOrSchema IS NULL) RS2
                ON a.ObjectID = RS2.id
        WHERE RS2.id IS NULL
        ORDER BY a.AuxiliaryOrdering, a.ObjectOwnerOrSchema, a.ObjectName

        SET @Cnt = @@ROWCOUNT
        
        IF @Cnt = 0
                SET @i = @i - 1
END

IF @IncludeWarningForCircularDependencies = 1
BEGIN
        IF OBJECT_ID('tempdb..#tblCircularDependencies') IS NOT NULL
                DROP TABLE #tblCircularDependencies
        
        CREATE TABLE #tblCircularDependencies(
                ObjectID INT NOT NULL PRIMARY KEY CLUSTERED,
                ObjectOwnerOrSchema NVARCHAR(128) COLLATE database_default,
                ObjectName NVARCHAR(128) COLLATE database_default,
                ObjectType NVARCHAR(128) COLLATE database_default,
                DepDescription NVARCHAR(128) COLLATE database_default)

        INSERT INTO #tblCircularDependencies(
                ObjectID,
                ObjectOwnerOrSchema,
                ObjectName,
                ObjectType,
                DepDescription)
        SELECT  a.ObjectID,
                a.ObjectOwnerOrSchema,
                a.ObjectName,
                a.ObjectType,
                'Child objects (e.g., triggers, etc.) depende on objects that cause a circular dependency'
        FROM #tblObjects a
                LEFT OUTER JOIN #tblDependencyAndDeploymentOrder b
                ON a.ObjectID = b.ObjectID
        WHERE b.ObjectID IS NULL
END

-- At this point we know that the remaining objects have circular dependency,
-- either through their child objects or directly.

-- Check dependencies, this time without taking into consideration the child objects.
-- If any records are found here, that means that we have circular dependencies.
SET @Cnt = 1

WHILE @Cnt > 0
BEGIN
        -- Analyze the next level in the hierarchy.
        SET @i = @i + 1


        -- This is the same check as the one above,
        -- however this time we do not check the child objects.
        -- This check is provided for dependency ordering only.

        INSERT INTO #tblDependencyAndDeploymentOrder (
                ObjectID, 
                ObjectOwnerOrSchema, 
                ObjectName, 
                QualifiedNameForObjectIDFn,
                ObjectType, 
                CircularDependency,
                IsEncrypted, 
                DependencyLevel)
        SELECT  a.ObjectID,
                a.ObjectOwnerOrSchema,
                a.ObjectName,
                N'[' + REPLACE(a.ObjectOwnerOrSchema, '''', '''''') + '].[' + REPLACE(a.ObjectName, '''', '''''') + ']',
                a.ObjectType,
                1,
                0,
                @i
        FROM #tblObjects a
                -- Objects in #tblObjects and not in #tblDependencyAndDeploymentOrder
                -- that depend on objects in #tblDependencyAndDeploymentOrder
                INNER JOIN
                (SELECT DISTINCT c.id
                FROM #tblObjects b
                        INNER JOIN #MySysdepends c
                        ON c.id = b.ObjectID
                        INNER JOIN #tblDependencyAndDeploymentOrder d
                        ON d.ObjectID = c.depid
                        LEFT OUTER JOIN #tblDependencyAndDeploymentOrder e WITH (NOLOCK)
                        ON c.id = e.ObjectID
                WHERE e.ObjectOwnerOrSchema IS NULL) RS1
                ON RS1.id = a.ObjectID
                -- Objects in #tblObjects that depend on objects not in #tblDependencyAndDeploymentOrder
                LEFT OUTER JOIN
                (SELECT DISTINCT w.id
                FROM #tblObjects v
                        INNER JOIN #MySysdepends w
                        ON w.id = v.ObjectID
                        INNER JOIN #tblObjects x
                        ON w.depid = x.ObjectID
                        LEFT OUTER JOIN #tblDependencyAndDeploymentOrder y
                        ON y.ObjectID = w.depid
                WHERE w.id <> w.depid
                        AND w.depType = 'D'
                        AND y.ObjectOwnerOrSchema IS NULL) RS2
                ON a.ObjectID = RS2.id
        WHERE RS2.id IS NULL
        ORDER BY a.AuxiliaryOrdering, a.ObjectOwnerOrSchema, a.ObjectName

        SET @Cnt = @@ROWCOUNT
        
        IF @Cnt = 0
                SET @i = @i - 1
END

-- Warn abount direct circular dependencies
IF @IncludeWarningForCircularDependencies = 1
BEGIN
        INSERT INTO #tblCircularDependencies(
                ObjectID,
                ObjectOwnerOrSchema,
                ObjectName,
                ObjectType,
                DepDescription)
        SELECT  a.ObjectID,
                a.ObjectOwnerOrSchema,
                a.ObjectName,
                a.ObjectType,
                'Circular dependency was found for the object'
        FROM #tblObjects a
                LEFT OUTER JOIN #tblDependencyAndDeploymentOrder b
                ON a.ObjectID = b.ObjectID
                LEFT OUTER JOIN #tblCircularDependencies c
                ON a.ObjectID = c.ObjectID
        WHERE b.ObjectID IS NULL
                AND c.ObjectID IS NULL
END

-- Here we record the remaining objects (which include direct circular dependencies).
-- This is rare, however must be considered.

SET @i = @i + 1

INSERT INTO #tblDependencyAndDeploymentOrder (
        ObjectID, 
        ObjectOwnerOrSchema, 
        ObjectName,
        QualifiedNameForObjectIDFn,
        ObjectType, 
        CircularDependency,
        IsEncrypted, 
        DependencyLevel)
SELECT  a.ObjectID,
        a.ObjectOwnerOrSchema,
        a.ObjectName,
        N'[' + REPLACE(a.ObjectOwnerOrSchema, '''', '''''') + '].[' + REPLACE(a.ObjectName, '''', '''''') + ']',
        a.ObjectType,
        1,
        0,
        @i
FROM #tblObjects a
        LEFT OUTER JOIN #tblDependencyAndDeploymentOrder b
        ON a.ObjectID = b.ObjectID
WHERE b.ObjectOwnerOrSchema IS NULL
ORDER BY a.AuxiliaryOrdering, a.ObjectOwnerOrSchema, a.ObjectName

-- Return the requested results
IF @ReturnFoundDependencies = 1
BEGIN
--        SELECT 'The table below contains all dependencies found'

        SELECT  id,
                idObjectOwnerOrSchema,
                idObjectName,
                idObjectType,
                depid,
                depidObjectOwnerOrSchema,
                depidObjectName,
                depidObjectType,
                CASE
                WHEN depType = 'D' THEN 'Direct dependency found in sys.sql_dependencies'
                WHEN depType = 'C' THEN 'Dependency via child-objects found in sys.sql_dependencies'
                WHEN depType = 'S' THEN 'Direct dependency found in text-based searches'
                WHEN depType = 'T' THEN 'Dependency via child-objects found in text-based searches'
                END depType
        FROM #MySysdepends
END

IF @ReturnDeploymentOrder = 1
BEGIN
--        SELECT 'The table below contains the object deployment order and dependency hierarchy level'

        SELECT *
        FROM #tblDependencyAndDeploymentOrder
        ORDER BY DeploymentOrder
END

IF @IncludeWarningForCircularDependencies = 1
BEGIN
--        SELECT 'The table below contains the circular dependencies found'

        SELECT *
        FROM #tblCircularDependencies
END

--====================================================================
-- Step 4 Completed
--====================================================================


GO