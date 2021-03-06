-- a first way to bulk extract section
-- next steps are: 1. remove no relevant section
-- 2. add missing section from manual read
-- 3. map sections to loinc
-- 4. run the existing UIMA extract_section pipeline 
-- 5. load the OMOP note_nlp table

-- set search_path TO mimiciii;
-- DROP  MATERIALIZED VIEW  noteevents_section_count ;
-- CREATE MATERIALIZED VIEW noteevents_section_count  AS
-- WITH section_regex (category, regex) AS ( VALUES
-- ('Nursing/other', ''), --NO SECTION, free text
-- ('Nursing', '([A-z]+:)'), --OK
-- ('Radiology', '[ ]*([A-Z ]+:)'), --OK
-- ('ECG', ''),-- NO SECTION
-- ('Physician ', '[ ]*([A-Z]+[A-Z ]+:)'),-- OK
-- ('Discharge summary', '\n[ ]*\n([A-z0-9 ]+)(:| WERE | INCLUD | IS | ARE)'),-- OK
-- ('Discharge summary', '\n([A-Z]+[A-Z ]+:)\n'),-- OK
-- ('Echo', '[ ]*([A-Z]+[A-Z ]+:)'),-- OK
-- ('Respiratory ', '\n[ ]*([A-Z][a-z ]+:)'),-- OK
-- ('Nutrition', '\n[ ]*([A-Z][a-z ]+:)'),-- OK
-- ('General', '\n[ ]*([A-Z][a-z ]+:)'), -- OK, not sure relevant
-- ('Rehab Services', '\n[ ]*([A-Z][a-z ]+:)'), --OK
-- ('Social Work', '\n[ ]*([A-Z][a-z ]+:)'), -- OK
-- ('Case Management ', '\n[ ]*([A-Z][a-z ]+:)'),-- OK
-- ('Pharmacy', '\n[ ]*([A-Z][A-Z]*[a-z ]*[:]{0,1})'),-- OK, but many false positive
-- ('Consult', '\n[ ]*([A-Z][a-z ]+:)'), -- OK
-- ('','')
-- ),
-- all_label AS (SELECT row_id, category, unnest(regexp_matches(text, regex, 'g')) as label
-- FROM (SELECT row_id, category, regex, text
-- 	FROM noteevents 
-- 	JOIN section_regex USING ( category )
-- 	 ) AS TMP 
-- )
-- SELECT count(1), category, label
-- FROM all_label
-- GROUP BY category, label
-- ORDER BY category, count DESC;
-- \copy (WITH tot AS (SELECT count(1) as nb, category FROM noteevents GROUP BY category),
-- tmp AS (
-- SELECT * FROM mimiciii.noteevents_section_count
-- LEFT JOIN tot USING (category)
-- WHERE count > 200
-- )
-- SELECT * , ( count::float / nb::float * 100::float ) as percent_avec_section FROM tmp
-- GROUP BY tmp.category, label, count, nb
-- ORDER BY tmp.category, percent_avec_section DESC) TO '/tmp/section_list.csv' CSV HEADER;


set search_path TO mimiciii;
DROP  MATERIALIZED VIEW  noteevents_section_count ;
CREATE MATERIALIZED VIEW noteevents_section_count  AS
WITH
"section_regex" (category, regex) AS ( VALUES
	('Nursing/other', ''),
	('Nursing', '\n[ ]*([A-z0-9/ ]+:)'),
	('Radiology', '\n[ ]*([A-z0-9/ ]+:)'),
	('ECG', ''),
	('Physician ', '\n[ ]*([A-z0-9/ ]+:)'),
	('Discharge summary', '\n[ ]*([A-z0-9/ ]+:)'),
	('Echo', '\n[ ]*([A-z0-9/ ]+:)'),
	('Respiratory ', '\n[ ]*([A-z0-9/ ]+:)'),
	('Nutrition', '\n[ ]*([A-z0-9/ ]+:)'),
	('General', '\n[ ]*([A-z0-9/ ]+:)'),
	('Rehab Services', '\n[ ]*([A-z0-9/ ]+:)'),
	('Social Work', '\n[ ]*([A-z0-9/ ]+:)'),
	('Case Management ', '\n[ ]*([A-z0-9/ ]+:)'),
	('Pharmacy', '\n[ ]*([A-z0-9/ ]+:)'),
	('Consult', '\n[ ]*([A-z0-9/ ]+:)'),
	('','')
),
"all_label" AS (SELECT row_id, category, unnest(regexp_matches(text, regex, 'g')) as label
	FROM (SELECT row_id, category, regex, text
		FROM noteevents
		JOIN section_regex USING ( category )
	) AS TMP
),
"tmp2" AS (SELECT count(1), category, label
	FROM all_label
	GROUP BY category, label
	ORDER BY category, count DESC),
"tot" AS (SELECT count(1) as nb, category
	FROM noteevents
	GROUP BY category),
tmp AS (
	SELECT *
	FROM tmp2
	LEFT JOIN tot USING (category)
)
SELECT * , ( count::float / nb::float * 100::float ) as percent_avec_section FROM tmp
GROUP BY tmp.category, label, count, nb
HAVING ( count::float / nb::float * 100::float ) between 0 and 100 AND length(label) > 1
ORDER BY tmp.category, percent_avec_section DESC
;

-- export notes to avro
with 
cat_name as (SELECT distinct category from noteevents ORDER BY 1), 
categories as ( SELECT category, row_number() over() as cat_id from cat_name) 
SELECT row_id, cat_id, text 
FROM  noteevents 
LEFT JOIN categories USING (category) LIMIT 10;

-- export section pattern to avro
-- ref_doc_section.csv
-- no header

\copy (WITH                                                                                                                                  
cat_name as (SELECT distinct category from noteevents ORDER BY 1),
categories as ( SELECT category, row_number() over() as cat_id from cat_name)
select row_number() over() as section_id, cat_id, label
from noteevents_section_count  
LEFT JOIN categories USING (category)
where percent_avec_section >= 1 and count >=10 and  (length(label) >2 or label ~* '^[A-z]+:$') order by length(label) desc)
TO '/tmp/ref_doc_section.csv' CSV QUOTE '"';

with
cat_name as (SELECT distinct category from mimiciii.noteevents ORDER BY 1),
categories as ( SELECT category, row_number() over() as cat_id from cat_name)
SELECT section_code as section_id, category_code as category_id, category, section_text as  label, '' as label_mapped
FROM omop.tmp_note_nlp_concept
left join categories on category_code = cat_id ;

-- mapping label
\copy (select 
distinct on (section_id)
 section_id      
, category_id     
, category        
, label           
, label_mapped    
, first_value(note_nlp.lexical_variant) over(partition by section_id) as extrait
from mimic.gcpt_note_section_to_concept a
LEFT JOIN omop.note_nlp ON mimic_id = section_source_concept_id)
TO '/tmp/ivan.csv' CSV HEADER FORCE QUOTE *;
