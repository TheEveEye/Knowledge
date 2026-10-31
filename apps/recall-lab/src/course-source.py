"""Extract the actual required course content, preserving PDF page and topic provenance."""
import hashlib, json, re, sys
import pdfplumber
source, output = sys.argv[1:]
topics = {}; current = None
with pdfplumber.open(source) as pdf:
    for index, page in enumerate(pdf.pages):
        words = page.extract_words()
        full = page.extract_text() or ''
        topic = re.search(r'\bTOPIC\s+([1-5]\.\d+)\b', full)
        if topic:
            current = topic[1]
        headings = [w for w in words if w['text'] == 'ESSENTIAL' and any(x['text'] == 'KNOWLEDGE' and abs(x['top'] - w['top']) < 3 and x['x0'] > w['x0'] for x in words)]
        if not current or not headings:
            continue
        heading = headings[0]
        # This column boundary is discovered from each page's actual header position.
        column = page.crop((max(0, heading['x0'] - 2), heading['bottom'] + 2, page.width - 25, page.height - 55))
        raw = column.extract_text() or ''
        lines = [line.rstrip() for line in raw.splitlines() if not re.search(r'continued on next page|Return to Table|©|Course Framework', line)]
        text = '\n'.join(lines).strip()
        if not re.search(r'\b' + re.escape(current) + r'\.[A-Z]\.\d+', text):
            continue
        bucket = topics.setdefault(current, [])
        bucket.append({'pdfPage': index + 1, 'text': text})
sections = []
for topic, pages in topics.items():
    # Split at knowledge identifiers, retaining subordinate meaning and original page references.
    for page in pages:
        parts = re.split(r'(?m)(?=^' + re.escape(topic) + r'\.[A-Z]\.\d+\s*$)', page['text'])
        for n, part in enumerate(parts):
            if len(part.strip()) < 60:
                continue
            if len(part) > 9000:
                raise RuntimeError(f'Topic {topic}, PDF page {page["pdfPage"]} requires smaller source segmentation')
            title = 'Topic ' + topic
            split = 'holdout' if int(hashlib.sha256(title.encode()).hexdigest()[:8], 16) % 5 == 0 else 'development'
            identity = f'{topic}:{page["pdfPage"]}:{n}'
            sections.append({'id': hashlib.sha256(identity.encode()).hexdigest()[:16], 'title': title,
                'topic': topic, 'unit': topic.split('.')[0], 'text': part.strip(), 'split': split,
                'provenance': {'sourceURL': 'https://apcentral.collegeboard.org/media/pdf/ap-psychology-course-and-exam-description.pdf',
                    'pdfPage': page['pdfPage'], 'sourceSHA256': hashlib.sha256(open(source, 'rb').read()).hexdigest()}})
if set(s['unit'] for s in sections) != set('12345') or len(topics) < 30:
    raise RuntimeError('Incomplete course extraction; inspect the PDF layout instead of using a partial corpus')
with open(output, 'w') as f:
    json.dump(sections, f, indent=2, ensure_ascii=False)
print(json.dumps({'sections': len(sections), 'topics': len(topics), 'units': sorted(set(s['unit'] for s in sections)),
    'holdoutTopics': sorted(set(s['topic'] for s in sections if s['split'] == 'holdout'))}))
