CREATE PROC [dbo].[p_GetDependencies]
	@ObjectName VARCHAR(50)
AS
BEGIN
	DECLARE @find_referencing_objects INT
	SET @find_referencing_objects = 0
	-- parameters:
	-- 1. create table #tempdep (objid int NOT NULL, objtype smallint NOT NULL)
	--    contains source objects
	-- 2. @find_referencing_objects defines ordering
	--    1 order for drop
	--    0 order for script
	
	DECLARE @must_set_nocount_off BIT
	SET @must_set_nocount_off = 0
	
	IF @@OPTIONS & 512 = 0
	    SET @must_set_nocount_off = 1
	
	SET NOCOUNT ON
	
	DECLARE @u INT
	DECLARE @udf INT
	DECLARE @v INT
	DECLARE @sp INT
	DECLARE @def INT
	DECLARE @rule INT
	DECLARE @tr INT
	DECLARE @uda INT
	DECLARE @uddt INT
	DECLARE @xml INT
	DECLARE @udt INT
	DECLARE @assm INT
	DECLARE @part_sch INT
	DECLARE @part_func INT
	DECLARE @synonym INT
	DECLARE @pg INT
	
	SET @u = 3
	SET @udf = 0
	SET @v = 2
	SET @sp = 4
	SET @def = 6
	SET @rule = 7
	SET @tr = 8
	SET @uda = 11
	SET @synonym = 12
	--above 100 -> not in sys.objects
	SET @uddt = 101
	SET @xml = 102
	SET @udt = 103
	SET @assm = 1000
	SET @part_sch = 201
	SET @part_func = 202
	SET @pg = 204
	
	CREATE TABLE #tempdep
	(
		objid INT NOT NULL, objname SYSNAME NOT NULL, objschema SYSNAME NULL, objdb SYSNAME NOT NULL, objtype SMALLINT NOT NULL
	)
	INSERT INTO #tempdep
	SELECT OBJECT_ID, NAME, SCHEMA_NAME(SCHEMA_ID), DB_NAME(), CASE 
	                                                                WHEN obj.type = 'U' THEN @u
	                                                                WHEN obj.type = 'V' THEN @v
	                                                                WHEN obj.type = 'TR' THEN @tr
	                                                                WHEN obj.type IN ('P', 'RF', 'PC') THEN @sp
	                                                                WHEN obj.type IN ('AF') THEN @uda
	                                                                WHEN obj.type IN ('TF', 'FN', 'IF', 'FS', 'FT') THEN @udf
	                                                                WHEN obj.type = 'D' THEN @def
	                                                                WHEN obj.type = 'SN' THEN @synonym
	                                                                ELSE 20
	                                                           END
	FROM   sys.objects obj
	WHERE  OBJECT_ID = OBJECT_ID(@ObjectName)
	
	
	/*
	* Create #t1 as temp object holding areas.  Columns are:
	*  object_id     - temp object id
	*  object_type    - temp object type
	*  relative_id      - parent or child object id
	*  relative_type  - parent or child object type
	*  rank  - NULL means dependencies not yet evaluated, else nonNULL.
	*   soft_link - this row should not be used to compute ordering among objects
	*   object_name - name of the temp object
	*   object_schema - name the temp object's schema (if any)
	*   relative_name - name of the relative object
	*   relative_schema - name of the relative object's schema (if any)
	*   degree - the number of relatives that the object has, will be used for computing the rank
	*   object_key - surrogate key that combines object_id and object_type
	*   relative_key - surrogate key that combines relative_id and relative_type
	*/
	CREATE TABLE #t1
	(
		OBJECT_ID INT NULL, object_type SMALLINT NULL, relative_id INT NULL, relative_type SMALLINT NULL, RANK SMALLINT NULL, soft_link BIT NULL, OBJECT_NAME SYSNAME NULL, 
		object_schema SYSNAME NULL, relative_name SYSNAME NULL, relative_schema SYSNAME NULL, degree INT NULL, object_key BIGINT NULL, relative_key BIGINT NULL
	)
	
	CREATE UNIQUE CLUSTERED INDEX i1 ON #t1(OBJECT_ID, object_type, relative_id, relative_type) WITH IGNORE_DUP_KEY
	
	DECLARE @iter_no INT
	SET @iter_no = 1
	
	DECLARE @rows INT
	SET @rows = 1
	
	DECLARE @rowcount_ck INT
	SET @rowcount_ck = 0
	
	INSERT #t1
	  (
	    relative_id, relative_type, RANK
	  )
	SELECT l.objid, l.objtype, @iter_no
	FROM   #tempdep l
	
	WHILE @rows > 0
	BEGIN
	    SET @rows = 0
	    IF (1 = @find_referencing_objects)
	    BEGIN
	        --tables that reference uddts or udts (parameters that reference types are in sql_dependencies )
	        INSERT #t1
	          (
	            OBJECT_ID, object_type, relative_id, relative_type, RANK
	          )
	        SELECT t.relative_id, t.relative_type, c.object_id, @u, @iter_no + 1
	        FROM   #t1               AS t
	               JOIN sys.columns  AS c
	                    ON  c.user_type_id = t.relative_id
	               JOIN sys.tables   AS tbl
	                    ON  tbl.object_id = c.object_id -- eliminate views
	        WHERE  @iter_no = t.rank
	               AND (t.relative_type = @uddt OR t.relative_type = @udt)
	        
	        SET @rows = @rows + @@rowcount
	        
	        --tables that reference defaults ( only default objects )
	        INSERT #t1
	          (
	            OBJECT_ID, object_type, relative_id, relative_type, RANK
	          )
	        SELECT t.relative_id, t.relative_type, clmns.object_id, @u, @iter_no + 1
	        FROM   #t1               AS t
	               JOIN sys.columns  AS clmns
	                    ON  clmns.default_object_id = t.relative_id
	               JOIN sys.objects  AS o
	                    ON  o.object_id = t.relative_id
	                        AND 0 = ISNULL(o.parent_object_id, 0)
	        WHERE  @iter_no = t.rank
	               AND t.relative_type = @def
	        
	        SET @rows = @rows + @@rowcount
	        
	        --types that reference defaults ( only default objects )
	        INSERT #t1
	          (
	            OBJECT_ID, object_type, relative_id, relative_type, RANK
	          )
	        SELECT t.relative_id, t.relative_type, tp.user_type_id, @uddt, @iter_no + 1
	        FROM   #t1               AS t
	               JOIN sys.types    AS tp
	                    ON  tp.default_object_id = t.relative_id
	               JOIN sys.objects  AS o
	                    ON  o.object_id = t.relative_id
	                        AND 0 = ISNULL(o.parent_object_id, 0)
	        WHERE  @iter_no = t.rank
	               AND t.relative_type = @def
	        
	        SET @rows = @rows + @@rowcount
	        
	        --tables that reference rules
	        INSERT #t1
	          (
	            OBJECT_ID, object_type, relative_id, relative_type, RANK
	          )
	        SELECT t.relative_id, t.relative_type, clmns.object_id, @u, @iter_no + 1
	        FROM   #t1               AS t
	               JOIN sys.columns  AS clmns
	                    ON  clmns.rule_object_id = t.relative_id
	        WHERE  @iter_no = t.rank
	               AND t.relative_type = @rule
	        
	        SET @rows = @rows + @@rowcount
	        
	        --types that reference rules
	        INSERT #t1
	          (
	            OBJECT_ID, object_type, relative_id, relative_type, RANK
	          )
	        SELECT t.relative_id, t.relative_type, tp.user_type_id, @uddt, @iter_no + 1
	        FROM   #t1             AS t
	               JOIN sys.types  AS tp
	                    ON  tp.rule_object_id = t.relative_id
	        WHERE  @iter_no = t.rank
	               AND t.relative_type = @rule
	        
	        SET @rows = @rows + @@rowcount
	        
	        --tables that reference XmlSchemaCollections
	        INSERT #t1
	          (
	            OBJECT_ID, object_type, relative_id, relative_type, RANK
	          )
	        SELECT t.relative_id, t.relative_type, c.object_id, @u, @iter_no + 1
	        FROM   #t1               AS t
	               JOIN sys.columns  AS c
	                    ON  c.xml_collection_id = t.relative_id
	               JOIN sys.tables   AS tbl
	                    ON  tbl.object_id = c.object_id -- eliminate views
	        WHERE  @iter_no = t.rank
	               AND t.relative_type = @xml
	        
	        SET @rows = @rows + @@rowcount
	        
	        --procedures that reference XmlSchemaCollections
	        INSERT #t1
	          (
	            OBJECT_ID, object_type, relative_id, relative_type, RANK
	          )
	        SELECT t.relative_id, t.relative_type, c.object_id, CASE 
	                                                                 WHEN o.type IN ('P', 'RF', 'PC') THEN @sp
	                                                                 ELSE @udf
	                                                            END, @iter_no + 1
	        FROM   #t1                  AS t
	               JOIN sys.parameters  AS c
	                    ON  c.xml_collection_id = t.relative_id
	               JOIN sys.objects     AS o
	                    ON  o.object_id = c.object_id
	        WHERE  @iter_no = t.rank
	               AND t.relative_type = @xml
	        
	        SET @rows = @rows + @@rowcount
	        
	        --udf, sp, uda, trigger all that reference assembly
	        INSERT #t1
	          (
	            OBJECT_ID, object_type, relative_id, relative_type, RANK
	          )
	        SELECT t.relative_id, t.relative_type, am.object_id, (
	                   CASE o.type
	                        WHEN 'AF' THEN @uda
	                        WHEN 'PC' THEN @sp
	                        WHEN 'FS' THEN @udf
	                        WHEN 'FT' THEN @udf
	                        WHEN 'TA' THEN @tr
	                        ELSE @udf
	                   END
	               ), @iter_no + 1
	        FROM   #t1               AS t
	               JOIN sys.assembly_modules AS am
	                    ON  am.assembly_id = t.relative_id
	               JOIN sys.objects  AS o
	                    ON  am.object_id = o.object_id
	        WHERE  @iter_no = t.rank
	               AND t.relative_type = @assm
	        
	        SET @rows = @rows + @@rowcount
	        
	        -- CLR udf, sp, uda that reference udt
	        INSERT #t1
	          (
	            OBJECT_ID, object_type, relative_id, relative_type, RANK
	          )
	        SELECT DISTINCT t.relative_id, t.relative_type, am.object_id, (
	                   CASE o.type
	                        WHEN 'AF' THEN @uda
	                        WHEN 'PC' THEN @sp
	                        WHEN 'FS' THEN @udf
	                        WHEN 'FT' THEN @udf
	                        WHEN 'TA' THEN @tr
	                        ELSE @udf
	                   END
	               ), @iter_no + 1
	        FROM   #t1                  AS t
	               JOIN sys.parameters  AS sp
	                    ON  sp.user_type_id = t.relative_id
	               JOIN sys.assembly_modules AS am
	                    ON  sp.object_id = am.object_id
	               JOIN sys.objects     AS o
	                    ON  sp.object_id = o.object_id
	        WHERE  @iter_no = t.rank
	               AND t.relative_type = @udt
	        
	        SET @rows = @rows + @@rowcount
	        
	        --udt that reference assembly
	        INSERT #t1
	          (
	            OBJECT_ID, object_type, relative_id, relative_type, RANK
	          )
	        SELECT t.relative_id, t.relative_type, at.user_type_id, @udt, @iter_no + 1
	        FROM   #t1 AS t
	               JOIN sys.assembly_types AS at
	                    ON  at.assembly_id = t.relative_id
	        WHERE  @iter_no = t.rank
	               AND t.relative_type = @assm
	        
	        SET @rows = @rows + @@rowcount
	        
	        --assembly that reference assembly
	        INSERT #t1
	          (
	            OBJECT_ID, object_type, relative_id, relative_type, RANK
	          )
	        SELECT t.relative_id, t.relative_type, ar.assembly_id, @assm, @iter_no + 1
	        FROM   #t1 AS t
	               JOIN sys.assembly_references AS ar
	                    ON  ar.referenced_assembly_id = t.relative_id
	        WHERE  @iter_no = t.rank
	               AND t.relative_type = @assm
	        
	        SET @rows = @rows + @@rowcount
	        
	        --table references table
	        INSERT #t1
	          (
	            OBJECT_ID, object_type, relative_id, relative_type, RANK
	          )
	        SELECT t.relative_id, t.relative_type, fk.parent_object_id, @u, @iter_no + 1
	        FROM   #t1                    AS t
	               JOIN sys.foreign_keys  AS fk
	                    ON  fk.referenced_object_id = t.relative_id
	        WHERE  @iter_no = t.rank
	               AND t.relative_type = @u
	        
	        SET @rows = @rows + @@rowcount
	        
	        --table,view references partition scheme
	        INSERT #t1
	          (
	            OBJECT_ID, object_type, relative_id, relative_type, RANK
	          )
	        SELECT t.relative_id, t.relative_type, idx.object_id, CASE o.type
	                                                                   WHEN 'V' THEN @v
	                                                                   ELSE @u
	                                                              END, @iter_no + 1
	        FROM   #t1               AS t
	               JOIN sys.indexes  AS idx
	                    ON  idx.data_space_id = t.relative_id
	               JOIN sys.objects  AS o
	                    ON  o.object_id = idx.object_id
	        WHERE  @iter_no = t.rank
	               AND t.relative_type = @part_sch
	        
	        SET @rows = @rows + @@rowcount
	        
	        --partition scheme references partition function
	        INSERT #t1
	          (
	            OBJECT_ID, object_type, relative_id, relative_type, RANK
	          )
	        SELECT t.relative_id, t.relative_type, ps.data_space_id, @part_sch, @iter_no + 1
	        FROM   #t1 AS t
	               JOIN sys.partition_schemes AS ps
	                    ON  ps.function_id = t.relative_id
	        WHERE  @iter_no = t.rank
	               AND t.relative_type = @part_func
	        
	        SET @rows = @rows + @@rowcount
	        
	        --non-schema-bound parameter references type
	        INSERT #t1
	          (
	            OBJECT_ID, object_type, relative_id, relative_type, RANK
	          )
	        SELECT t.relative_id, t.relative_type, p.object_id, CASE 
	                                                                 WHEN obj.type IN ('P', 'PC') THEN @sp
	                                                                 ELSE @udf
	                                                            END, @iter_no + 1
	        FROM   #t1                  AS t
	               JOIN sys.parameters  AS p
	                    ON  p.user_type_id = t.relative_id
	                        AND t.relative_type IN (@uddt, @udt)
	               JOIN sys.objects     AS obj
	                    ON  obj.object_id = p.object_id
	                        AND obj.type IN ('P', 'PC', 'TF', 'FN', 'IF', 'FS', 'FT')
	                        AND ISNULL(OBJECTPROPERTY(obj.object_id, 'isschemabound'), 0) = 0
	        WHERE  @iter_no = t.rank
	        
	        SET @rows = @rows + @@rowcount
	        
	        -- plan guide references sp, udf, triggers
	        INSERT #t1
	          (
	            OBJECT_ID, object_type, relative_id, relative_type, RANK
	          )
	        SELECT t.relative_id, t.relative_type, pg.plan_guide_id, @pg, @iter_no + 1
	        FROM   #t1                   AS t
	               JOIN sys.plan_guides  AS pg
	                    ON  pg.scope_object_id = t.relative_id
	        WHERE  @iter_no = t.rank
	               AND t.relative_type IN (@sp, @udf, @tr)
	        
	        SET @rows = @rows + @@rowcount
	        
	        --view, procedure references table, view, procedure
	        --procedure references type
	        --table(check) references procedure
	        --trigger references table, procedure
	        INSERT #t1
	          (
	            OBJECT_ID, object_type, relative_id, relative_type, RANK
	          )
	        SELECT t.relative_id, t.relative_type, CASE 
	                                                    WHEN 'C' = obj.type THEN obj.parent_object_id
	                                                    ELSE dp.object_id
	                                               END, CASE 
	                                                         WHEN obj.type  IN ('U', 'C') THEN @u
	                                                         WHEN 'V' = obj.type THEN @v
	                                                         WHEN 'TR' = obj.type THEN @tr
	                                                         WHEN obj.type IN ('P', 'RF', 'PC') THEN @sp
	                                                         WHEN obj.type IN ('TF', 'FN', 'IF', 'FS', 'FT') THEN @udf
	                                                    END, @iter_no + 1
	        FROM   #t1               AS t
	               JOIN sys.sql_dependencies AS dp
	                    ON  -- reference table, view procedure
	                        (class < 2 AND dp.referenced_major_id = t.relative_id AND t.relative_type IN (@u, @v, @sp, @udf))
	                        --reference type
	                        OR (2 = class AND dp.referenced_major_id = t.relative_id AND t.relative_type IN (@uddt, @udt))
	                        --reference xml namespace ( not supported by server right now )
	                        --or ( 3 = class  and dp.referenced_major_id = t.relative_id and @xml = t.relative_type )
	               JOIN sys.objects  AS obj
	                    ON  obj.object_id = dp.object_id
	                        AND obj.type IN ('U', 'V', 'P', 'RF', 'PC', 'TR', 'TF', 'FN', 'IF', 'FS', 'FT', 'C')
	        WHERE  @iter_no = t.rank
	        
	        SET @rows = @rows + @@rowcount
	    END-- 1 = @find_referencing_objects
	    ELSE
	    BEGIN
	        -- find referenced objects
	        --check references table
	        INSERT #t1
	          (
	            OBJECT_ID, object_type, relative_id, relative_type, RANK
	          )
	        SELECT t.relative_id, t.relative_type, dp.object_id, 77 /*place holder for check*/, @iter_no
	        FROM   #t1               AS t
	               JOIN sys.sql_dependencies AS dp
	                    ON  -- reference table
	                        class < 2
	                        AND dp.referenced_major_id = t.relative_id
	                        AND t.relative_type = @u
	               JOIN sys.objects  AS obj
	                    ON  obj.object_id = dp.object_id
	                        AND obj.type = 'C'
	        WHERE  @iter_no = t.rank
	        
	        SET @rowcount_ck = @@rowcount
	        
	        --non-schema-bound parameter references type
	        INSERT #t1
	          (
	            OBJECT_ID, object_type, relative_id, relative_type, RANK
	          )
	        SELECT DISTINCT 
	               t.relative_id, 	-- object_id
	               t.relative_type, 	-- object_type
	               p.user_type_id, 	-- relative_id
	               CASE p.system_type_id
	                    WHEN 240 THEN @udt
	                    ELSE @uddt
	               END, @iter_no + 1
	        FROM   #t1                  AS t
	               JOIN sys.parameters  AS p
	                    ON  p.object_id = t.relative_id
	                        AND p.user_type_id > 256
	                        AND t.relative_type IN (@sp, @udf, @uda)
	                        AND ISNULL(OBJECTPROPERTY(p.object_id, 'isschemabound'), 0) = 0
	        WHERE  @iter_no = t.rank
	        
	        SET @rows = @rows + @@rowcount
	        
	        --view, procedure referenced by table, view, procedure
	        --type referenced by procedure
	        --check referenced by table
	        INSERT #t1
	          (
	            OBJECT_ID, object_type, relative_id, relative_type, RANK
	          )
	        SELECT DISTINCT 
	               CASE 
	                    WHEN 77 = t.relative_type THEN obj2.parent_object_id
	                    ELSE t.relative_id
	               END, 	-- object_id
	               CASE 
	                    WHEN 77 = t.relative_type THEN @u
	                    ELSE relative_type
	               END, 	-- object_type
	               dp.referenced_major_id, 	-- relative_id
	               CASE -- relative_type
	                    WHEN dp.class < 2 THEN CASE 
	                                                WHEN 'U' = obj.type THEN @u
	                                                WHEN 'V' = obj.type THEN @v
	                                                WHEN 'TR' = obj.type THEN @tr
	                                                WHEN 'AF' = obj.type THEN @uda
	                                                WHEN obj.type IN ('P', 'RF', 'PC') THEN @sp
	                                                WHEN obj.type IN ('TF', 'FN', 'IF', 'FS', 'FT') THEN @udf
	                                                WHEN EXISTS (
	                                                         SELECT *
	                                                         FROM   sys.synonyms syn
	                                                         WHERE  syn.object_id = dp.referenced_major_id
	                                                     ) THEN @synonym
	                                           END
	                    WHEN dp.class = 2 THEN (
	                             CASE 
	                                  WHEN EXISTS (
	                                           SELECT *
	                                           FROM   sys.assembly_types sat
	                                           WHERE  sat.user_type_id = dp.referenced_major_id
	                                       ) THEN @udt
	                                  ELSE @uddt
	                             END
	                         )
	               END, @iter_no + 1
	        FROM   #t1                    AS t
	               JOIN sys.sql_dependencies AS dp
	                    ON  -- reference table, view procedure
	                        (class < 2 AND dp.object_id = t.relative_id AND t.relative_type IN (@u, @v, @sp, @udf, @tr, @uda, 77))
	                        --reference type
	                        OR (2 = class AND dp.object_id = t.relative_id) -- t.relative_type?
	                                                                        --reference xml namespace ( not supported by server right now )
	                                                                        --or ( 3 = class  and dp.referenced_major_id = t.relative_id and @xml = t.relative_type )
	                        
	               LEFT JOIN sys.objects  AS obj
	                    ON  obj.object_id = dp.referenced_major_id
	                        AND dp.class < 2
	                        AND obj.type IN ('U', 'V', 'P', 'RF', 'PC', 'TF', 'FN', 'IF', 'FS', 'FT', 'TR', 'AF')
	               LEFT JOIN sys.objects  AS obj2
	                    ON  obj2.object_id = t.relative_id
	                        AND 77 = t.relative_type
	        WHERE  @iter_no = t.rank
	        
	        SET @rows = @rows + @@rowcount
	        
	        IF @rowcount_ck > 0
	        BEGIN
	            DELETE 
	            FROM   #t1
	            WHERE  relative_type = 77
	        END
	        
	        --table or view referenced by trigger
	        INSERT #t1
	          (
	            OBJECT_ID, object_type, relative_id, relative_type, RANK
	          )
	        SELECT t.relative_id, t.relative_type, tr.parent_id, CASE o.type
	                                                                  WHEN 'V' THEN @v
	                                                                  ELSE @u
	                                                             END, @iter_no + 1
	        FROM   #t1                AS t
	               JOIN sys.triggers  AS tr
	                    ON  tr.object_id = t.relative_id
	               JOIN sys.objects   AS o
	                    ON  o.object_id = tr.parent_id
	        WHERE  @iter_no = t.rank
	               AND t.relative_type = @tr
	        
	        SET @rows = @rows + @@rowcount
	        
	        --table referenced by table
	        --insert #t1 (object_id, object_type, relative_id, relative_type, rank)
	        --   select t.relative_id, t.relative_type, fk.referenced_object_id, @u, @iter_no + 1
	        --   from #t1 as t
	        --   join sys.foreign_keys as fk on fk.parent_object_id = t.relative_id
	        --   where @iter_no = t.rank and t.relative_type = @u
	        --set @rows = @rows + @@rowcount
	        
	        --assembly referenced by assembly
	        INSERT #t1
	          (
	            OBJECT_ID, object_type, relative_id, relative_type, RANK
	          )
	        SELECT t.relative_id, t.relative_type, ar.referenced_assembly_id, @assm, @iter_no + 1
	        FROM   #t1 AS t
	               JOIN sys.assembly_references AS ar
	                    ON  ar.assembly_id = t.relative_id
	        WHERE  @iter_no = t.rank
	               AND t.relative_type = @assm
	        
	        SET @rows = @rows + @@rowcount
	        
	        --assembly referenced by udt
	        INSERT #t1
	          (
	            OBJECT_ID, object_type, relative_id, relative_type, RANK
	          )
	        SELECT t.relative_id, t.relative_type, at.assembly_id, @assm, @iter_no + 1
	        FROM   #t1 AS t
	               JOIN sys.assembly_types AS at
	                    ON  at.user_type_id = t.relative_id
	        WHERE  @iter_no = t.rank
	               AND t.relative_type = @udt
	        
	        SET @rows = @rows + @@rowcount
	        
	        -- assembly referenced by udf, sp, uda, trigger
	        INSERT #t1
	          (
	            OBJECT_ID, object_type, relative_id, relative_type, RANK
	          )
	        SELECT t.relative_id, t.relative_type, am.assembly_id, @assm, @iter_no + 1
	        FROM   #t1 AS t
	               JOIN sys.assembly_modules AS am
	                    ON  am.object_id = t.relative_id
	        WHERE  @iter_no = t.rank
	               AND t.relative_type IN (@udf, @sp, @uda, @tr)
	        
	        SET @rows = @rows + @@rowcount
	        
	        -- udt referenced by CLR udf, sp, uda
	        INSERT #t1
	          (
	            OBJECT_ID, object_type, relative_id, relative_type, RANK
	          )
	        SELECT DISTINCT 
	               t.relative_id, t.relative_type, at.user_type_id, @udt, @iter_no + 1
	        FROM   #t1                  AS t
	               JOIN sys.parameters  AS sp
	                    ON  sp.object_id = t.relative_id
	               JOIN sys.assembly_modules AS am
	                    ON  am.object_id = sp.object_id
	               JOIN sys.assembly_types AS at
	                    ON  sp.user_type_id = at.user_type_id
	        WHERE  @iter_no = t.rank
	               AND t.relative_type IN (@udf, @sp, @uda)
	        
	        SET @rows = @rows + @@rowcount
	        
	        --clr types referenced by tables ( types referenced by parameters are in sql_dependencies )
	        INSERT #t1
	          (
	            OBJECT_ID, object_type, relative_id, relative_type, RANK
	          )
	        SELECT t.relative_id, t.relative_type, c.user_type_id, @udt, @iter_no + 1
	        FROM   #t1               AS t
	               JOIN sys.columns  AS c
	                    ON  c.object_id = t.relative_id
	               JOIN sys.assembly_types AS tp
	                    ON  tp.user_type_id = c.user_type_id
	        WHERE  @iter_no = t.rank
	               AND t.relative_type = @u
	        
	        SET @rows = @rows + @@rowcount
	        
	        -- sp, udf, triggers referenced by plan guide
	        INSERT #t1
	          (
	            OBJECT_ID, object_type, relative_id, relative_type, RANK
	          )
	        SELECT t.relative_id, t.relative_type, pg.scope_object_id, (CASE o.type WHEN 'P' THEN @sp WHEN 'TR' THEN @tr ELSE @udf END), @iter_no + 1
	        FROM   #t1                   AS t
	               JOIN sys.plan_guides  AS pg
	                    ON  pg.plan_guide_id = t.relative_id
	               JOIN sys.objects      AS o
	                    ON  o.object_id = pg.scope_object_id
	        WHERE  @iter_no = t.rank
	               AND t.relative_type = @pg
	        
	        SET @rows = @rows + @@rowcount
	    END
	    SET @iter_no = @iter_no + 1
	END --main loop
	
	--objects that don't need to be in the loop because they don't reference anybody
	IF (0 = @find_referencing_objects)
	BEGIN
	    --alias types referenced by tables ( types referenced by parameters are in sql_dependencies )
	    INSERT #t1
	      (
	        OBJECT_ID, object_type, relative_id, relative_type, RANK
	      )
	    SELECT t.relative_id, t.relative_type, c.user_type_id, @uddt, @iter_no + 1
	    FROM   #t1               AS t
	           JOIN sys.columns  AS c
	                ON  c.object_id = t.relative_id
	           JOIN sys.types    AS tp
	                ON  tp.user_type_id = c.user_type_id
	                    AND tp.is_user_defined = 1
	    WHERE  t.relative_type = @u
	           AND tp.is_assembly_type = 0
	    
	    IF @@rowcount > 0
	    BEGIN
	        SET @iter_no = @iter_no + 1
	    END
	    
	    --defaults referenced by types
	    INSERT #t1
	      (
	        OBJECT_ID, object_type, relative_id, relative_type, RANK
	      )
	    SELECT t.relative_id, t.relative_type, tp.default_object_id, @def, @iter_no + 1
	    FROM   #t1               AS t
	           JOIN sys.types    AS tp
	                ON  tp.user_type_id = t.relative_id
	                    AND tp.default_object_id > 0
	           JOIN sys.objects  AS o
	                ON  o.object_id = tp.default_object_id
	                    AND 0 = ISNULL(o.parent_object_id, 0)
	    WHERE  t.relative_type = @uddt
	    
	    --defaults referenced by tables( only default objects )
	    INSERT #t1
	      (
	        OBJECT_ID, object_type, relative_id, relative_type, RANK
	      )
	    SELECT t.relative_id, t.relative_type, clmns.default_object_id, @def, @iter_no + 1
	    FROM   #t1               AS t
	           JOIN sys.columns  AS clmns
	                ON  clmns.object_id = t.relative_id
	           JOIN sys.objects  AS o
	                ON  o.object_id = clmns.default_object_id
	                    AND 0 = ISNULL(o.parent_object_id, 0)
	    WHERE  t.relative_type = @u
	    
	    --rules referenced by types
	    INSERT #t1
	      (
	        OBJECT_ID, object_type, relative_id, relative_type, RANK
	      )
	    SELECT t.relative_id, t.relative_type, tp.rule_object_id, @rule, @iter_no + 1
	    FROM   #t1             AS t
	           JOIN sys.types  AS tp
	                ON  tp.user_type_id = t.relative_id
	                    AND tp.rule_object_id > 0
	    WHERE  t.relative_type = @uddt
	    
	    --rules referenced by tables
	    INSERT #t1
	      (
	        OBJECT_ID, object_type, relative_id, relative_type, RANK
	      )
	    SELECT t.relative_id, t.relative_type, clmns.rule_object_id, @rule, @iter_no + 1
	    FROM   #t1               AS t
	           JOIN sys.columns  AS clmns
	                ON  clmns.object_id = t.relative_id
	                    AND clmns.rule_object_id > 0
	    WHERE  t.relative_type = @u
	    
	    --XmlSchemaCollections referenced by table
	    INSERT #t1
	      (
	        OBJECT_ID, object_type, relative_id, relative_type, RANK
	      )
	    SELECT t.relative_id, t.relative_type, c.xml_collection_id, @xml, @iter_no + 1
	    FROM   #t1               AS t
	           JOIN sys.columns  AS c
	                ON  c.object_id = t.relative_id
	                    AND c.xml_collection_id > 0
	    WHERE  t.relative_type = @u
	    
	    --XmlSchemaCollections referenced by procedures
	    INSERT #t1
	      (
	        OBJECT_ID, object_type, relative_id, relative_type, RANK
	      )
	    SELECT t.relative_id, t.relative_type, c.xml_collection_id, @xml, @iter_no + 1
	    FROM   #t1                  AS t
	           JOIN sys.parameters  AS c
	                ON  c.object_id = t.relative_id
	                    AND c.xml_collection_id > 0
	    WHERE  t.relative_type IN (@sp, @udf)
	    
	    --partition scheme referenced by table,view
	    INSERT #t1
	      (
	        OBJECT_ID, object_type, relative_id, relative_type, RANK
	      )
	    SELECT t.relative_id, t.relative_type, ps.data_space_id, @part_sch, @iter_no + 1
	    FROM   #t1               AS t
	           JOIN sys.indexes  AS idx
	                ON  idx.object_id = t.relative_id
	           JOIN sys.partition_schemes AS ps
	                ON  ps.data_space_id = idx.data_space_id
	    WHERE  t.relative_type IN (@u, @v)
	    
	    --partition function referenced by partition scheme
	    INSERT #t1
	      (
	        OBJECT_ID, object_type, relative_id, relative_type, RANK
	      )
	    SELECT t.relative_id, t.relative_type, ps.function_id, @part_func, @iter_no + 1
	    FROM   #t1 AS t
	           JOIN sys.partition_schemes AS ps
	                ON  ps.data_space_id = t.relative_id
	    WHERE  t.relative_type = @part_sch
	END
	
	--cleanup circular references
	DELETE #t1
	WHERE  OBJECT_ID = relative_id
	       AND object_type = relative_type
	
	--allow circular dependencies by cuting one of the branches
	--mark as soft links dependencies between tables
	-- at script time we will need to take care to script fks and checks separately
	UPDATE #t1
	SET    soft_link = 1
	WHERE  (object_type = @u AND relative_type = @u)
	
	--add independent objects first in the list
	INSERT #t1
	  (
	    OBJECT_ID, object_type, RANK
	  )
	SELECT t.relative_id, t.relative_type, 1
	FROM   #t1 t
	WHERE  t.relative_id NOT IN (SELECT t2.object_id
	                             FROM   #t1 t2
	                             WHERE  NOT t2.object_id IS NULL)
	
	--delete initial objects
	DELETE #t1
	WHERE  OBJECT_ID IS NULL
	
	-- compute the surrogate keys to make sorting easier
	UPDATE #t1
	SET    object_key = OBJECT_ID + CONVERT(BIGINT, 0xfFFFFFFF) * object_type
	
	UPDATE #t1
	SET    relative_key = relative_id + CONVERT(BIGINT, 0xfFFFFFFF) * relative_type
	
	CREATE INDEX index_key ON #t1(object_key, relative_key)
	
	UPDATE #t1
	SET    RANK = 0
	-- computing the degree of the nodes
	UPDATE #t1
	SET    degree = (
	           SELECT COUNT(*)
	           FROM   #t1 t_alias
	           WHERE  t_alias.object_key = #t1.object_key
	                  AND t_alias.relative_id IS NOT NULL
	                  AND t_alias.soft_link IS NULL
	       )
	
	-- perform topological sorting 
	SET @iter_no = 1
	WHILE 1 = 1
	BEGIN
	    UPDATE #t1
	    SET    RANK = @iter_no
	    WHERE  degree = 0
	    -- end the loop if no more rows left to process
	    IF (@@rowcount = 0)
	        BREAK
	    
	    UPDATE #t1
	    SET    degree = NULL
	    WHERE  RANK = @iter_no
	    
	    UPDATE #t1
	    SET    degree = (
	               SELECT COUNT(*)
	               FROM   #t1 t_alias
	               WHERE  t_alias.object_key = #t1.object_key
	                      AND t_alias.relative_key IS NOT NULL
	                      AND t_alias.relative_key IN (SELECT t_alias2.object_key
	                                                   FROM   #t1 t_alias2
	                                                   WHERE  t_alias2.rank = 0
	                                                          AND t_alias2.soft_link IS NULL)
	                      AND t_alias.rank = 0
	                      AND t_alias.soft_link IS NULL
	           )
	    WHERE  degree IS NOT NULL
	    
	    SET @iter_no = @iter_no + 1
	END
	
	--add name schema
	UPDATE #t1
	SET    OBJECT_NAME = o.name, object_schema = SCHEMA_NAME(o.schema_id)
	FROM   sys.objects AS o
	WHERE  o.object_id = #t1.object_id
	       AND object_type IN (@u, @udf, @v, @sp, @def, @rule, @uda)
	
	UPDATE #t1
	SET    relative_type = CASE op.type
	                            WHEN 'V' THEN @v
	                            ELSE @u
	                       END, OBJECT_NAME = o.name, object_schema = SCHEMA_NAME(o.schema_id), relative_name = op.name, relative_schema = SCHEMA_NAME(op.schema_id)
	FROM   sys.objects AS o
	       JOIN sys.objects AS op
	            ON  op.object_id = o.parent_object_id
	WHERE  o.object_id = #t1.object_id
	       AND object_type = @tr
	
	UPDATE #t1
	SET    OBJECT_NAME = t.name, object_schema = SCHEMA_NAME(t.schema_id)
	FROM   sys.types AS t
	WHERE  t.user_type_id = #t1.object_id
	       AND object_type IN (@uddt, @udt)
	
	UPDATE #t1
	SET    OBJECT_NAME = x.name, object_schema = SCHEMA_NAME(x.schema_id)
	FROM   sys.xml_schema_collections AS x
	WHERE  x.xml_collection_id = #t1.object_id
	       AND object_type = @xml
	
	UPDATE #t1
	SET    OBJECT_NAME = p.name, object_schema = NULL
	FROM   sys.partition_schemes AS p
	WHERE  p.data_space_id = #t1.object_id
	       AND object_type = @part_sch
	
	
	UPDATE #t1
	SET    OBJECT_NAME = p.name, object_schema = NULL
	FROM   sys.partition_functions AS p
	WHERE  p.function_id = #t1.object_id
	       AND object_type = @part_func
	
	UPDATE #t1
	SET    OBJECT_NAME = pg.name, object_schema = NULL
	FROM   sys.plan_guides AS pg
	WHERE  pg.plan_guide_id = #t1.object_id
	       AND object_type = @pg
	
	UPDATE #t1
	SET    OBJECT_NAME = a.name, object_schema = NULL
	FROM   sys.assemblies AS a
	WHERE  a.assembly_id = #t1.object_id
	       AND object_type = @assm
	
	UPDATE #t1
	SET    OBJECT_NAME = syn.name, object_schema = SCHEMA_NAME(syn.schema_id)
	FROM   sys.synonyms AS syn
	WHERE  syn.object_id = #t1.object_id
	       AND object_type = @synonym
	
	-- delete objects for which we could not resolve the table name or schema
	-- because we may not have enough privileges
	DELETE 
	FROM   #t1
	WHERE  OBJECT_NAME IS NULL
	       OR (object_schema IS NULL AND object_type NOT IN (@assm, @part_func, @part_sch, @pg))
	
	--final select
	SELECT DISTINCT CASE 
	                     WHEN t.object_schema IS NULL THEN ''
	                     ELSE t.object_schema + '.'
	                END + t.object_name [object_fullname], OBJECT_ID, object_type 
	       --, relative_id, relative_type, 
	       OBJECT_NAME, object_schema
	       --, relative_name, relative_schema
	FROM   #t1 t
	WHERE  t.object_id <> OBJECT_ID(@ObjectName)
	--order by rank, relative_id
	
	DROP TABLE #t1
	DROP TABLE #tempdep
	
	IF @must_set_nocount_off > 0
	    SET NOCOUNT OFF
END
GO