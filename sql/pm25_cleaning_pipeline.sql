-- -------------------------------------------------------------------------------------------------------- SETUP CODES
-- Creates a fresh database for the project
CREATE DATABASE un_pediatric_health;

-- Activates our fresh database
USE un_pediatric_health;

-- creates table inside this active database
CREATE TABLE raw_pediatric_admissions (
    admission_id INT,
    admission_date VARCHAR(50), -- Messy text format
    age INT,
    respiratory_condition VARCHAR(100),
    pm25_level DECIMAL(10,2),
    hospital_zone VARCHAR(50),
    ventilator_used VARCHAR(10) -- Stored as text to allow messy nulls/strings
);

-- Populates the table with our messy data rows
INSERT INTO raw_pediatric_admissions VALUES
	(101, '2024-08-12', 5, 'Asthma', 45.20, 'North', 'False'),
	(102, '12/08/2024', 8, 'Bronchitis', NULL, 'South', 'True'), -- NULL PM2.5
	(103, 'August 13, 2024', 12, 'Asthma', -999.00, 'North', 'False'), -- Malfunctioning PM2.5
	(104, '2024-08-14', 3, 'Pneumonia', 68.50, 'East', 'True'), -- Duplicate record
	(104, '2024-08-14', 3, 'Pneumonia', 68.50, 'East', 'True'), 
	(105, '2024-08-15', 14, 'Asthma', 12.10, NULL, 'False'); -- NULL zone

-- Creates a staging table copy by pulling everything from the raw table
CREATE TABLE stg_pediatric_admissions AS 
SELECT * FROM raw_pediatric_admissions;

-- ---------------------------------------------------------------------------------------------------------- ANALYSIS CODES
SELECT * 
FROM stg_pediatric_admissions;

-- Query to identify duplicate admission IDs in the staging table
SELECT admission_id, COUNT(*)
FROM stg_pediatric_admissions
GROUP BY admission_id
HAVING COUNT(*) > 1;

-- (REMOVING DUPLICATES)
-- Creates a temporary holding table containing only distinct (unique) rows
CREATE TEMPORARY TABLE temp_dedup AS 
SELECT DISTINCT * 
FROM stg_pediatric_admissions;

-- Wipes the active staging table clean so we can reload the deduplicated data
TRUNCATE TABLE stg_pediatric_admissions;

-- Copy the clean, unique rows from the temporary table back into staging
INSERT INTO stg_pediatric_admissions 
SELECT * 
FROM temp_dedup;

-- Destroy the temporary holding table to free up database memory
DROP TEMPORARY TABLE temp_dedup;

-- Verify that only one unique record remains for ID 104
SELECT * 
FROM stg_pediatric_admissions 
WHERE admission_id = 104;

-- (DEALING WITH NULLS)
-- Query to find which admissions have no hospital zone recorded
SELECT * 
FROM stg_pediatric_admissions
WHERE hospital_zone IS NULL;

-- Filters out admissions with missing spatial data (zones) to prevent mapping errors
DELETE FROM stg_pediatric_admissions
WHERE hospital_zone IS NULL;

-- Impute missing PM2.5 for south zone patients (we only have a single south zone and has NULL pm25)
UPDATE stg_pediatric_admissions
SET pm25_level = (
    SELECT COALESCE(
        -- Attempt 1: South Zone Average
        (SELECT AVG(temp1.pm25_level) 
			FROM (SELECT * FROM stg_pediatric_admissions) AS temp1
			WHERE temp1.hospital_zone = 'South' 
				AND temp1.pm25_level IS NOT NULL),
        -- Attempt 2: Global City-Wide Average Fallback
        (SELECT AVG(temp2.pm25_level) 
			FROM (SELECT * FROM stg_pediatric_admissions) AS temp2
			WHERE temp2.pm25_level IS NOT NULL 
				AND temp2.pm25_level > 0.00)
	)
)
WHERE pm25_level IS NULL 
  AND hospital_zone = 'South';
  
-- Verify the imputation for the South Zone patient (ID 102)
SELECT * 
FROM stg_pediatric_admissions 
WHERE admission_id = 102;

-- (CORRECT MALFUNCTIONING SENSOR OUTLIERS (-999.00))
-- Replaces negative sensor error codes with valid neighborhood averages to protect mathematical integrity
UPDATE stg_pediatric_admissions
SET pm25_level = (
    -- Calculate the average of valid readings in the North Zone
    SELECT AVG(temp.pm25_level) 
    FROM (SELECT * FROM stg_pediatric_admissions) AS temp
    WHERE temp.hospital_zone = 'North' 
      AND temp.pm25_level > 0.00
)
WHERE pm25_level <= 0.00 
  AND hospital_zone = 'North';
  
-- Verify that Patient 103's sensor outlier was successfully cleaned
SELECT * 
FROM stg_pediatric_admissions 
WHERE admission_id = 103;  

-- (PERMANENTLY STANDARDIZE DATE STRINGS IN STAGING)
-- Updates the VARCHAR date column into standard DATE 
UPDATE stg_pediatric_admissions
SET admission_date = CASE 
    -- Catches standard hyphens (e.g., '2024-08-12')
    WHEN admission_date LIKE '%-%' AND LENGTH(admission_date) = 10
        THEN DATE_FORMAT(STR_TO_DATE(admission_date, '%Y-%m-%d'), '%Y-%m-%d')
        
    -- Catches any slashes (e.g., '12/08/2024' or '12/8/2024')
    WHEN admission_date LIKE '%/%'
        THEN DATE_FORMAT(STR_TO_DATE(admission_date, '%d/%m/%Y'), '%Y-%m-%d')
        
    -- Catches any verbose dates (e.g., 'September 15, 2024')
    WHEN LENGTH(admission_date) > 10 AND admission_date LIKE '%,%'
        THEN DATE_FORMAT(STR_TO_DATE(admission_date, '%M %d, %Y'), '%Y-%m-%d')
        
    ELSE NULL 
END;

-- Permanently alters the column structure to DATE 
ALTER TABLE stg_pediatric_admissions
MODIFY COLUMN admission_date DATE;

-- Verify the schema conversion
DESCRIBE stg_pediatric_admissions;

-- Displays final clean data
SELECT * 
FROM stg_pediatric_admissions;