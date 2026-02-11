# CypressMage 🧙 - AI-Powered Cypress Test Generator

**Conjure comprehensive Cypress tests from Koha bug test plans using the power of AI**

A Perl script that transforms test plans into production-ready Cypress tests automatically.

## Installation

Required Perl modules:
```bash
cpanm LWP::UserAgent JSON File::Slurp Term::ANSIColor
```

## Setup

### Option 1: Using GitHub Models API (Recommended)
```bash
export GITHUB_TOKEN="ghp_your_github_token"
```

Get your token from: https://github.com/settings/tokens

**Note:** GitHub Models API is the default provider.

### Option 2: Using OpenAI API
```bash
export OPENAI_API_KEY="sk-your-openai-api-key"
```

Get your API key from: https://platform.openai.com/api-keys

Then use `--provider openai` flag when running the script.

### Set Koha Directory
```bash
export KOHA_PATH=/path/to/your/Koha
```

## Usage

### Basic Usage
```bash

# Generate test from a file
./cypress_mage.pl --bug 39802 --test-plan example_testplan.txt

# Generate test from inline text
./cypress_mage.pl --bug 39802 --text "1. Go to staff interface
2. Search for a patron
3. Check the logs"
```

### Advanced Usage
```bash
# Use OpenAI API instead of GitHub (default is GitHub)
./cypress_mage.pl --bug 39802 --test-plan example_testplan.txt --provider openai

# Specify custom output location
./cypress_mage.pl --bug 39802 --test-plan example_testplan.txt --output t/cypress/integration/MyTest_spec.ts

# Use different model
./cypress_mage.pl --bug 39802 --test-plan example_testplan.txt --model gpt-4-turbo
```

## Complete Workflow Example

```bash
# Navigate to cypress-mage directory
cd ~/cypress-mage

# 1. Create a test plan file (or copy from bug report)
cat > bug39802_testplan.txt << 'EOF'
1. Go to a staff interface
2. Go to page http://localhost:8081/cgi-bin/koha/members/member-flags.pl?member=<borrowernumber>
3. Select checkbox inside parent-flag-catalogue on the member-flags.tt page and save the permission
EOF

# 2. Generate the Cypress test (it will be saved to ~/Koha by default)
./cypress_mage.pl --bug 39802 --test-plan bug39802_testplan.txt

# 3. Run the generated test
cd ~/Koha
npm run cypress open
# or headless:
npm run cypress run -- --spec "t/cypress/integration/Generated/Bug39802_spec.ts"
```

## How CypressMage Works

CypressMage generates:
1. Complete TypeScript test file with proper imports
2. `describe()` block with test suite setup
3. `beforeEach()` with login and test data creation
4. One or more `it()` test cases (auto-grouped by steps)
5. `afterEach()` with cleanup
6. Saved to: `$KOHA_PATH/t/cypress/integration/Generated/Bug<NUMBER>_spec.ts`

The generated tests are ready to run immediately! large test plans into multiple test cases
5. **Outputs TypeScript** - Generates complete, runnable Cypress tests with proper setup/teardown

## Output

The script will:
1. Read your test plan
2. Send it to AI (GitHub Models by default, or OpenAI)
3. Generate a complete Cypress TypeScript test
4. Save it to `$KOHA_PATH/t/cypress/integration/Generated/Bug<NUMBER>_spec.ts` (default: `~/Koha/t/cypress/integration/Generated/`)
5. Display instructions for running the test

## Writing Effective Test Plans

The quality of generated tests depends heavily on how you write your test plan. Follow these guidelines for best results.

### Basic Structure

Use numbered steps (1, 2, 3, etc.) to describe your test scenario. The bot will translate each step into Cypress commands.

**Example:**
```
1. Go to staff interface
2. Search for a patron
3. Click on the patron's name
4. Verify the patron details page is displayed
```
CypressMage
### Grouping Tests (Automatic Batching)

When you have many steps, the bot automatically groups them into separate test cases (every 3 steps). You can also manually separate test groups using `---`:

**Example from Bug-20956:**
```
1. Go to a staff interface
2. Go to page http://localhost:8081/cgi-bin/koha/members/member-flags.pl?member=<borrowernumber>
3. Select checkbox inside parent-flag-catalogue on the member-flags.tt page and save the permission
---
4. Go to /cgi-bin/koha/tools/viewlog.pl?do_it=1&modules=MEMBERS&object=<borrowernumber>&src=circ
5. Find table #logst from viewlog.tt
6. Verify that info column has value {catalogue: 1}
```

This creates:
- First test case: Steps 1-3 (setup and action)
- Second test case: Steps 4-6 (verification)

Both tests share the same `describe()` block and use the same test data (no duplicate logins or patron creation).

### Be Specific About Elements

**Instead of:**
```
3. Click the save button
```

**Write:**
```
3. Click the submit button with id #save_patron
```

Or reference the template file:
```
3. Select checkbox inside parent-flag-catalogue on member-flags.tt
```

### Include URLs When Needed

Provide exact URLs, especially for complex pages with parameters:

**Good:**
```
2. Go to /cgi-bin/koha/members/member-flags.pl?member=<borrowernumber>
```

**Also Good (for reference files):**
```
2. Go to member-flags.pl with the patron's borrowernumber
```

### Specify What to Verify

Be precise about what to check and where. Include:
- The element to check (ID, class, or description)
- The expected value or behavior
- Which column/field to verify (if in a table)

**Vague:**
```
6. Check the logs
```

**Specific (Better):**
```
6. Verify that info column in #logst table has value {catalogue: 1}
```

**Even Better:**
```
6. Find table #logst from viewlog.tt and verify that info column (column index 3) has value {catalogue: 1}
```
CypressMage
### Reference Template Files

When you mention .tt, .pl, or .pm files, the bot will extract relevant HTML elements (IDs, classes, form fields) to help generate accurate selectors:

**Example:**
```
3. Select checkbox inside parent-flag-catalogue on the member-flags.tt page
5. Find table #logst from viewlog.tt
```

CypressMage will:
1. Locate these files in your Koha installation
2. Extract relevant context (forms, IDs, classes)
3. Use them to generate precise selectors

### Use Placeholders for Dynamic Data

Use standard placeholders that CypressMage understands:

- `<borrowernumber>` → Will use `patron.patron_id`
- `<biblionumber>` → Will use `biblio.biblio_id`
- `<itemnumber>` → Will use `item.item_id`

**Example:**
```
2. Go to /cgi-bin/koha/members/member-flags.pl?member=<borrowernumber>
4. Filter by Object = <borrowernumber>
```

### What NOT to Include

❌ **Don't include "before patch" scenarios** - CypressMage assumes the patch is already applied

❌ **Don't add extra verification steps** - Only include what the test plan requires

❌ **Avoid vague instructions** like "check it works" - Be specific about what to verify

### Complete Example: Bug-20956

```
1. Go to a staff interface
2. Go to page http://localhost:8081/cgi-bin/koha/members/member-flags.pl?member=<borrowernumber>
3. Select checkbox inside parent-flag-catalogue on the member-flags.tt page and save the permission
---
4. Go to /cgi-bin/koha/tools/viewlog.pl?do_it=1&modules=MEMBERS&object=<borrowernumber>&src=circ
5. Find table #logst from viewlog.tt
6. Verify that info column has value {catalogue: 1}
```

This generates:
- A complete describe() block with beforeEach (login + create patron) and afterEach (cleanup)
- First it() test: Steps 1-3 (setting the permission)
- Second it() test: Steps 4-6 (verifying it was logged)
- Both tests use the same patron (no duplicate creation)

## Tips

- Be specific in your test plans - the more detail, the better the generated test
- Include expected results (==> lines)
- Mention specific UI elements (buttons, forms, etc.)
- Note any data that needs to be captured (like borrowernumber)

## Troubleshooting

### API Key Issues
```bash
# Verify your API key is set
echo $OPENAI_API_KEY
# or
echo $GITHUB_TOKEN
```

### Module Dependencies
```bash
# Install missing modules
cpanm --installdeps .
# or individually
cpanm LWP::UserAgent JSON File::Slurp Term::ANSIColor
```

### Permission Denied
```bash
chmod +x cypress_mage.pl
```

## Cost Considerations

- **GitHub Models API** is the default and recommended option for paid GitHub plans
- OpenAI API calls cost approximately $0.01-0.03 per test generation (gpt-4)
- GitHub Models offers access to various models including gpt-4o
- To use different models: `--model gpt-4o` or `--model gpt-3.5-turbo`

## Author

Johanna Räisä <johanna.raisa@gmail.com>

## License

GPL v3
