-- Repair the official catalog values that were imported as literal question
-- marks in an earlier local database initialization.
begin;

update public.currencies
set
  name = case code
    when 'YER' then U&'\0631\064A\0627\0644 \064A\0645\0646\064A'
    when 'SAR' then U&'\0631\064A\0627\0644 \0633\0639\0648\062F\064A'
    when 'USD' then U&'\062F\0648\0644\0627\0631 \0623\0645\0631\064A\0643\064A'
    when 'EUR' then U&'\064A\0648\0631\0648'
    when 'AED' then U&'\062F\0631\0647\0645 \0625\0645\0627\0631\0627\062A\064A'
    when 'KWD' then U&'\062F\064A\0646\0627\0631 \0643\0648\064A\062A\064A'
    when 'QAR' then U&'\0631\064A\0627\0644 \0642\0637\0631\064A'
    when 'BHD' then U&'\062F\064A\0646\0627\0631 \0628\062D\0631\064A\0646\064A'
    when 'OMR' then U&'\0631\064A\0627\0644 \0639\0645\0627\0646\064A'
    when 'GBP' then U&'\062C\0646\064A\0647 \0625\0633\062A\0631\0644\064A\0646\064A'
    when 'JPY' then U&'\064A\0646 \064A\0627\0628\0627\0646\064A'
    else name
  end,
  symbol = case code
    when 'YER' then U&'\0631.\064A'
    when 'SAR' then U&'\0631.\0633'
    when 'USD' then '$'
    when 'EUR' then U&'\20AC'
    when 'AED' then U&'\062F.\0625'
    when 'KWD' then U&'\062F.\0643'
    when 'QAR' then U&'\0631.\0642'
    when 'BHD' then U&'\062F.\0628'
    when 'OMR' then U&'\0631.\0639'
    when 'GBP' then U&'\00A3'
    when 'JPY' then U&'\00A5'
    else symbol
  end,
  updated_at = now()
where code in ('YER','SAR','USD','EUR','AED','KWD','QAR','BHD','OMR','GBP','JPY');

commit;
