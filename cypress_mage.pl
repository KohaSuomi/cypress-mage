#!/usr/bin/perl

use Modern::Perl;
use LWP::UserAgent;
use JSON qw(encode_json decode_json);
use Getopt::Long;
use File::Slurp qw(read_file write_file);
use File::Basename;
use Term::ANSIColor;
use XML::LibXML;
use C4::Context;

=head1 NAME

cypress_mage.pl - Generate Cypress tests from Koha bug test plans using AI

=head1 SYNOPSIS

    # Generate test from a test plan file
    ./cypress_mage.pl --test-plan test_plan.txt --bug 39802

    # Generate test from inline text
    ./cypress_mage.pl --bug 39802 --text "1. Go to staff interface\n2. Search patron"

    # Use GitHub Models API
    ./cypress_mage.pl --test-plan test_plan.txt --bug 39802 --provider github

    # Specify output file
    ./cypress_mage.pl --test-plan test_plan.txt --bug 39802 --output my_test.ts

=head1 DESCRIPTION

This script uses AI (OpenAI or GitHub Models) to automatically generate Cypress tests
from Koha bug test plans.

=cut

# Configuration
my $test_plan_file;
my $test_plan_text;
my $bug_number;
my $output_file;
my $provider = 'github';  # 'github' or 'openai'
my $model = 'gpt-4o';
my $host = 'http://localhost:8081';  # Koha web service URL
my $help;

GetOptions(
    'test-plan=s' => \$test_plan_file,
    'text=s'      => \$test_plan_text,
    'bug=s'       => \$bug_number,
    'output=s'    => \$output_file,
    'provider=s'  => \$provider,
    'model=s'     => \$model,
    'host=s'      => \$host,
    'help'        => \$help,
) or die "Error in command line arguments\n";

if ($help) {
    print_help();
    exit 0;
}

die "Error: Must provide either --test-plan or --text\n" 
    unless $test_plan_file || $test_plan_text;
die "Error: Must provide --bug number\n" unless $bug_number;

# Read test plan
my $test_plan;
if ($test_plan_file) {
    die "Error: Test plan file not found: $test_plan_file\n" unless -f $test_plan_file;
    $test_plan = read_file($test_plan_file);
} else {
    $test_plan = $test_plan_text;
}

unless ($ENV{GITHUB_TOKEN} || $ENV{OPENAI_API_KEY}) {
    say "export GITHUB_TOKEN=your_github_token  # for GitHub Models API (default)";
    say "export OPENAI_API_KEY=your_openai_api_key # for OPENAI API"; 
    die "Error: Must set GITHUB_TOKEN for GitHub provider or OPENAI_API_KEY for OpenAI provider\n";
}

my $KOHA_CONF = "$ENV{KOHA_CONF}";
my $parser = XML::LibXML->new();
my $doc = $parser->parse_file($KOHA_CONF);
our $DB_HOSTNAME = $doc->findvalue('//config/hostname') || '127.0.0.1';
our $DB_USER = $doc->findvalue('//config/user');
our $DB_PASSWORD = $doc->findvalue('//config/pass');
our $DB_NAME = $doc->findvalue('//config/database');

if ($ENV{DB_HOSTNAME} ne $DB_HOSTNAME || $ENV{DB_USER} ne $DB_USER || $ENV{DB_PASSWORD} ne $DB_PASSWORD || $ENV{DB_NAME} ne $DB_NAME) {
    say colored("Warning: Environment variables do not match Koha configuration.\n", 'yellow');
    say "export DB_HOSTNAME=$DB_HOSTNAME";
    say "export DB_USER=$DB_USER";
    say "export DB_PASSWORD=$DB_PASSWORD";
    say "export DB_NAME=$DB_NAME";
    die "Please ensure environment variables match Koha configuration or set them correctly.\n";
}

unless(find_test_user()) {
    die "For cypress tests there needs to be a test user 'koha' with password 'koha'";
}

unless (test_web_service()) {
    die "Error: Koha web service is not available at $host/cgi-bin/koha/mainpage.pl\n";
}

# Extract script references from test plan
my @script_files = extract_script_files($test_plan);

# Determine output filename first
unless ($output_file) {
    my $sanitized_bug = "Bug${bug_number}";
    # Default to Koha directory in the workspace
    my $koha_dir = $ENV{KOHA_PATH} || "$ENV{HOME}/Koha";
    $output_file = "${koha_dir}/t/cypress/integration/Generated/${sanitized_bug}_spec.ts";
}

# Create directory if it doesn't exist
my $dir = dirname($output_file);
unless (-d $dir) {
    system("mkdir", "-p", $dir);
    say colored("Created directory: $dir", 'yellow');
}

# Parse test plan into separate test steps/groups
my @test_steps = split_test_plan_into_steps($test_plan);
say colored("Parsed test plan into " . scalar(@test_steps) . " test group(s)", 'cyan') if @test_steps > 1;

# Process files in batches to avoid token limits (max ~1 file per batch to stay under 8000 tokens)
my $max_files_per_batch = 1;
my @file_batches;

if (@script_files) {
    say colored("Found " . scalar(@script_files) . " script reference(s): " . join(", ", @script_files), 'cyan');
    
    for (my $i = 0; $i < @script_files; $i += $max_files_per_batch) {
        my $end = $i + $max_files_per_batch - 1;
        $end = $#script_files if $end > $#script_files;
        push @file_batches, [@script_files[$i..$end]];
    }
} else {
    # No files, single batch with no context
    push @file_batches, [];
}

my $batch_num = 0;
foreach my $batch (@file_batches) {
    $batch_num++;
    my $batch_context = "";
    
    if (@$batch > 0) {
        say colored("Processing batch $batch_num/" . scalar(@file_batches) . " (" . scalar(@$batch) . " file(s))", 'cyan');
        $batch_context = fetch_script_files(@$batch);
    } else {
        say colored("Generating Cypress test for Bug $bug_number...", 'cyan');
    }
    
    # Determine which test step(s) to use for this batch
    my $current_test_plan = @test_steps > 0 && $batch_num <= @test_steps 
        ? $test_steps[$batch_num - 1] 
        : $test_plan;
    
    if ($batch_num == 1) {
        # First batch - generate complete test structure
        my $cypress_test = generate_cypress_test($current_test_plan, $bug_number, $batch_context, 0);
        write_file($output_file, $cypress_test);
        say colored("✓ Created initial test file", 'green');
    } else {
        # Subsequent batches - append new test cases to existing file
        say colored("  Appending additional test case from batch $batch_num...", 'yellow');
        my $additional_test = generate_cypress_test($current_test_plan, $bug_number, $batch_context, 1);
        append_test_to_file($output_file, $additional_test);
        say colored("  ✓ Appended test case", 'green');
    }
}

# Add signature to generated file
my $signature = "\n// Created-by: AI-generated test using $provider API with model $model\n";
append_to_file($output_file, $signature);

sub append_to_file {
    my ($file_path, $content) = @_;
    my $existing = read_file($file_path);
    write_file($file_path, $existing . $content);
}

# Process batches and generate/append tests (see below)
# ... batch processing happens here ...

say colored("✓ Cypress test generated successfully!", 'green');
say colored("File: $output_file", 'green');
say "";
say colored("To run the test:", 'cyan');
say "  cd ~/Koha";
say "  npm run cypress open";
say "  # or";
say "  npm run cypress run -- --spec \"$output_file\"";

sub test_web_service {

    my $ua = LWP::UserAgent->new(timeout => 30);
    my $url = "$host/cgi-bin/koha/mainpage.pl";  # Adjust as needed
    my $response;
    $response = $ua->get($url);

    unless ($response->is_success) {
        return 0;
    }

    return 1;
}

sub find_test_user {
    my $dbh = C4::Context->dbh;
    my $sth = $dbh->prepare('SELECT userid FROM borrowers where userid = "koha"');
    $sth->execute();
    my ($userid) = $sth->fetchrow_array();
    return 1 if $userid;
    return 0;
}

sub split_test_plan_into_steps {
    my ($test_plan) = @_;
    my @steps;
    
    # Split by common test plan patterns:
    # - Numbered groups (1-3, 4-6, etc.)
    # - "Test X:" patterns
    # - Empty lines followed by numbered lists
    
    # Try to detect if test plan has clear numbered groups
    my @lines = split /\n/, $test_plan;
    my $current_group = "";
    my @groups;
    my $last_number = 0;
    
    foreach my $line (@lines) {
        # Check if line starts with a number (step number)
        if ($line =~ /^\s*(\d+)[\.\)]\s/) {
            my $num = $1;
            
            # If we see 1-3 pattern (new group every 3 steps)
            if ($num == 1 || ($last_number > 0 && $num % 3 == 1)) {
                # Save previous group if exists
                push @groups, $current_group if $current_group;
                $current_group = $line . "\n";
            } else {
                $current_group .= $line . "\n";
            }
            $last_number = $num;
        } else {
            $current_group .= $line . "\n" if $current_group;
        }
    }
    
    # Add last group
    push @groups, $current_group if $current_group;
    
    # If we successfully split into groups, return them; otherwise return empty (use full plan)
    return @groups > 1 ? @groups : ();
}

sub append_test_to_file {
    my ($file_path, $new_test) = @_;
    
    # Read existing file
    my $existing_content = read_file($file_path);
    
    # Remove closing braces of describe block
    $existing_content =~ s/\}\);?\s*$//;
    
    # Clean up the new test (remove any markdown code fences)
    $new_test =~ s/^```typescript\s*\n//;
    $new_test =~ s/^```ts\s*\n//;
    $new_test =~ s/\n```\s*$//;
    
    # Append new test with proper indentation
    my $updated_content = $existing_content . "\n\n  " . $new_test . "\n});\n";
    
    # Write back to file
    write_file($file_path, $updated_content);
}

sub extract_script_files {
    my ($test_plan) = @_;
    my @files;
    
    # Match various patterns for script references
    # Examples: members/memberentry.pl, acqui/basket.tt, etc.
    # First, collect potential file patterns from test plan
    my @patterns;
    while ($test_plan =~ m{([a-z0-9_/-]+\.(pl|tt|inc|pm))(?:\s|,|\.|\)|$)}gi) {
        push @patterns, $1;
    }
    
    # Search Koha directory for matching files
    my $koha_dir = $ENV{KOHA_PATH};
    if (-d $koha_dir) {
        for my $pattern (@patterns) {
            # Try exact path first
            if (-f "$koha_dir/$pattern") {
                push @files, $pattern;
                next;
            }
            
            # Search for file by basename in common directories
            my $basename = File::Basename::basename($pattern);
            my @search_dirs = qw(
                koha-tmpl/intranet-tmpl/prog/en/modules
                koha-tmpl/opac-tmpl/bootstrap/en/modules
                members acqui cataloguing circ admin tools reports
                svc opac api
            );
            
            for my $dir (@search_dirs) {
                my $search_path = "$koha_dir/$dir";
                if (-d $search_path) {
                    my $found = `find "$search_path" -name "$basename" -type f 2>/dev/null | head -1`;
                    chomp $found;
                    if ($found && -f $found) {
                        # Convert to relative path
                        $found =~ s{^\Q$koha_dir/\E}{};
                        push @files, $found;
                        last;
                    }
                }
            }
        }
    } else {
        # Fallback to original behavior if Koha dir not found
        @files = @patterns;
    }
    # Remove duplicates
    my %seen;
    @files = grep { !$seen{$_}++ } @files;
    
    return @files;
}

sub fetch_script_files {
    my (@files) = @_;
    return "" unless @files;
    
    my $context = "\n\nRELEVANT SCRIPT FILES FROM KOHA REPOSITORY:\n\n";
    my $koha_dir = $ENV{KOHA_PATH};
    
    unless (-d $koha_dir) {
        say colored("  Warning: Koha directory not found at $koha_dir", 'red');
        return "";
    }
    
    for my $file (@files) {
        say colored("  Looking for: $file", 'yellow');
        
        my $full_path = "$koha_dir/$file";
        
        if (-f $full_path) {
            my $content = read_file($full_path);
            my @lines = split /\n/, $content;
            
            # Extract relevant sections based on context
            my $extracted = extract_relevant_context($content, \@lines, $file);
            
            if ($extracted) {
                $context .= "File: $file\n```\n$extracted\n```\n\n";
                say colored("  ✓ Found $file (extracted relevant sections from " . scalar(@lines) . " lines)", 'green');
            } else {
                # Fallback: use first 150 lines if no specific context found
                my $truncated = scalar(@lines) > 150 ? join("\n", @lines[0..149]) . "\n... (truncated)" : $content;
                $context .= "File: $file\n```\n$truncated\n```\n\n";
                say colored("  ✓ Found $file (" . scalar(@lines) . " lines, using first 150)", 'green');
            }
        } else {
            say colored("  ✗ Could not find $file at $full_path", 'red');
        }
    }
    
    return $context;
}

sub extract_relevant_context {
    my ($content, $lines_ref, $filename) = @_;
    my @lines = @$lines_ref;
    my @relevant_sections;
    
    # Extract key elements that are likely relevant for Cypress tests
    my @patterns = (
        qr/id\s*=\s*["']([^"']+)["']/i,           # HTML IDs
        qr/class\s*=\s*["']([^"']+)["']/i,        # CSS classes
        qr/<form[^>]*>/i,                          # Form tags
        qr/<button[^>]*>/i,                        # Button tags
        qr/<input[^>]*>/i,                         # Input tags
        qr/<select[^>]*>/i,                        # Select tags
        qr/<textarea[^>]*>/i,                      # Textarea tags
        qr/name\s*=\s*["']([^"']+)["']/i,         # Name attributes
        qr/data-\w+\s*=\s*["']([^"']+)["']/i,     # Data attributes
    );
    
    my %seen_lines;
    
    for my $i (0..$#lines) {
        my $line = $lines[$i];
        
        foreach my $pattern (@patterns) {
            if ($line =~ $pattern) {
                # Include context: 3 lines before and 5 lines after
                my $start = $i - 3 > 0 ? $i - 3 : 0;
                my $end = $i + 5 < $#lines ? $i + 5 : $#lines;
                
                for my $j ($start..$end) {
                    $seen_lines{$j} = 1;
                }
                last;
            }
        }
    }
    
    # If we found relevant lines, extract them
    if (keys %seen_lines) {
        my @sorted_lines = sort { $a <=> $b } keys %seen_lines;
        my $extracted = "";
        my $last_line = -10;
        
        foreach my $line_num (@sorted_lines) {
            # Add separator if there's a gap
            if ($line_num - $last_line > 1) {
                $extracted .= "\n... (lines omitted) ...\n\n" if $last_line >= 0;
            }
            $extracted .= $lines[$line_num] . "\n";
            $last_line = $line_num;
        }
        
        # Limit total size to ~300 lines worth of content
        my @extracted_lines = split /\n/, $extracted;
        if (@extracted_lines > 300) {
            return join("\n", @extracted_lines[0..299]) . "\n... (truncated)";
        }
        
        return $extracted;
    }
    
    return "";
}


sub generate_cypress_test {
    my ($test_plan, $bug_number, $script_context, $is_append) = @_;
    
    my $prompt = build_prompt($test_plan, $bug_number, $script_context, $is_append);
    
    if ($provider eq 'github') {
        return call_github_api($prompt);
    } else {
        return call_openai_api($prompt);
    }
}

sub build_prompt {
    my ($test_plan, $bug_number, $script_context, $is_append) = @_;
    
    # Add script context if available
    my $script_section = $script_context ? $script_context : "";
    
    my $format_instruction = $is_append
        ? "Generate ONLY an it() test block (not the full describe structure) that will be appended to an existing test file. 
        
        CRITICAL REQUIREMENTS FOR APPENDED TESTS:
        - Do NOT include describe(), beforeEach(), or afterEach() blocks
        - Do NOT call cy.login() - login happens in the shared beforeEach
        - Do NOT call cy.task('insertSamplePatron') or create ANY new test data
        - MUST use function() syntax: it('test name', function() { ... })
        - MUST access the existing patron via: const patron = this.objects_patron.patron;
        - The patron data is ALREADY created and available in the this.objects_patron variable
        - Just write the test steps using the existing patron - no setup needed"
        : "Generate a complete Cypress test in TypeScript that automates these steps.";
    
    return <<~PROMPT;
    Given this Koha bug test plan for Bug $bug_number:
    
    $test_plan
    $script_section
    $format_instruction
    Follow the patterns used in existing Koha Cypress tests.
    
    IMPORTANT TEST APPROACH:
    - Assume the patch is ALREADY APPLIED to the codebase
    - Generate tests that verify the functionality WORKS CORRECTLY with the patch
    - Do NOT create "before patch" tests that check for broken behavior
    - Focus on testing that the new/fixed feature works as expected
    - If the test plan mentions "before" and "after" patch, ONLY implement the "after" scenario
    - Find related classes and ID's from the Koha UI for selectors, avoiding general text selectors
    
    CRITICAL - TEST PLAN ADHERENCE:
    - ONLY test the exact steps specified in the test plan
    - Do NOT add extra tests for functions or features not mentioned in the test plan
    - Do NOT test every possible function on the page - only what the test plan requires
    - Stay strictly within the scope of the provided test plan
    - If the test plan has 5 steps, create tests for those 5 steps only
    - Do NOT assume additional testing is needed beyond what's explicitly stated
    - Do NOT add extra verification steps unless the test plan explicitly asks to verify
    - Do NOT re-check saved data or state unless the test plan says "verify that..."
    - If test plan says "click Save", just click Save - don't add verification afterward
    - Keep tests minimal - implement only what is written in the test plan, nothing more
    - NO verification/assertion/checking steps unless explicitly in test plan
    - NO "should be checked", "should contain", "should exist" unless required
    - After completing last step in test plan, END immediately
    - NO final verification step to "confirm it worked"
    - Literally translate test plan steps to code, nothing else
    - When test plan says "verify X has value Y", check for that EXACT value Y, not just existence
    - When test plan specifies what to verify in a column/field, check that specific column/field
    - Be PRECISE with assertions - if test plan mentions a specific value, verify that exact value
    
    Requirements:
    - Use TypeScript syntax
    - Start with cy.login() in beforeEach
    - Use SPECIFIC, UNIQUE selectors that target single elements (prefer IDs, then unique classes, then specific attributes)
    - AVOID generic selectors that match multiple elements (e.g., 'button', 'input[type="submit"]' without additional specificity)
    - Always ensure selectors target exactly ONE element before clicking, typing, or checking
    - If a selector might match multiple elements, add :first, :eq(0), or use .first() to target one
    - Use .within() to scope selectors to specific containers when needed
    - Combine selectors for uniqueness (e.g., '#formid button[type="submit"]' instead of just 'button')
    - Include timeouts for elements that may take time to load
    - Add proper assertions to verify each step
    - ONLY implement test steps that are explicitly listed in the test plan
    - Do NOT create additional tests beyond the test plan scope
    - Use descriptive test names that match the test plan steps
    - Include comments for each major step from the test plan
    - Handle async operations properly with cy.wait() or should assertions
    - Extract and reuse data like borrowernumber between steps
    - Use Koha-specific URL patterns (/cgi-bin/koha/...)
    
    Koha Cypress Plugin Tasks (available via cy.task()):
    - Database queries: cy.task('query', { sql: 'SELECT ...', params: [value1, value2] })
    - Insert test data: cy.task('insertSampleBiblio', { item_count: 2 })
    - Insert patron: cy.task('insertSamplePatron', { categorycode: 'PT' })
    - Insert hold: cy.task('insertSampleHold', { biblionumber, borrowernumber })
    - Insert checkout: cy.task('insertSampleCheckout', { itemnumber, borrowernumber })
    - Build sample data: cy.task('buildSampleObjects', { patrons: 1, biblios: 1 })
    - API calls: cy.task('apiGet', { endpoint: '/api/v1/patrons' })
    - API calls: cy.task('apiPost', { endpoint: '/api/v1/patrons', body: {...} })
    - API calls: cy.task('apiPut', { endpoint: '/api/v1/patrons/123', body: {...} })
    - API calls: cy.task('apiDelete', { endpoint: '/api/v1/patrons/123' })
    - Cleanup: cy.task('deleteSampleObjects', objects)

    IMPORTANT - Variable Naming Convention:
    - When accessing patron object from insertSamplePatron: use patron.patron_id (NOT borrowernumber)
    - When accessing biblio object: use biblio.biblio_id (NOT biblionumber)
    - When accessing item object: use item.item_id (NOT itemnumber)
    - API endpoints and objects use different field names than database/URL parameters
    - In URLs like /members/moremember.pl?borrowernumber=X, use patron.patron_id for the value
    - Example: cy.visit(\`/cgi-bin/koha/members/member-flags.pl?member=\${patron.patron_id}\`)
    
    REAL Examples from Koha Cypress tests:
    
    1. Basic test structure with data cleanup:
    describe("Test name", () => {
        beforeEach(() => {
            cy.login();
            cy.title().should("eq", "Koha staff interface");
            cy.task("insertSamplePatron").then(objects_patron => {
                cy.wrap(objects_patron).as("objects_patron");
            });
        });
        
        afterEach(function () {
            cy.task("deleteSampleObjects", this.objects_patron);
        });
        
        it("should do something", function () {
            const patron = this.objects_patron.patron;
            cy.visit(\`/cgi-bin/koha/members/moremember.pl?borrowernumber=\${patron.patron_id}\`);
            // test code
        });
    });
    
    2. Using cy.wrap and aliases for sharing data:
    cy.task("insertSamplePatron").then(objects_patron => {
        cy.wrap(objects_patron).as("objects_patron");
    });
    // Later access with: function() { const patron = this.objects_patron.patron; }
    
    3. Database query pattern:
    cy.task('query', {
      sql: 'SELECT * FROM borrowers WHERE borrowernumber = ?',
      params: [patron_id]
    }).then((result: any) => {
      expect(result).to.have.length(1);
    });
    
    4. Form interaction patterns:
    cy.get("form.patron_search_form").within(() => {
        cy.get("#searchmember").type("search term");
        cy.get("input[type='submit']").click();
    });
    
    5. Checking element text with regex:
    cy.get(".patronbriefinfo").should(\$el => {
        const displayedText = \$el.text().trim();
        expect(displayedText).to.match(/expected pattern/);
    });
    
    6. Visiting pages and waiting for elements:
    cy.visit("/cgi-bin/koha/members/members-home.pl");
    cy.get("#searchmember", { timeout: 10000 }).should("be.visible");
    
    7. API mocking with cy.intercept:
    cy.intercept("GET", "/api/v1/patrons*", {
        statusCode: 200,
        body: [{ patron_id: 1, surname: "Test" }],
    });
    
    8. Checking specific table column for exact value:
    // Check 4th column (index 3) for specific text
    cy.get("#table_id tbody tr").each((\$row) => {
        cy.wrap(\$row).find("td").eq(3).then((\$cell) => {
            const cellText = \$cell.text().trim();
            if (cellText.includes("expected_value")) {
                expect(cellText).to.contain("expected_value");
            }
        });
    });
    
    9. Verifying specific value in table column:
    // When test plan says "verify column X has value Y"
    cy.get("#logst tbody tr").each((\$row) => {
        cy.wrap(\$row).find("td").eq(3).then((\$infoColumn) => {
            const infoText = \$infoColumn.text().trim();
            if (infoText.includes("{catalogue: 1}")) {
                expect(infoText).to.contain("{catalogue: 1}");
            }
        });
    });
    
    IMPORTANT:
    - Use 'query' NOT 'queryDb' for database tasks
    - Use 'sql' and 'params' properties, NOT 'query' and 'values'
    - Always type result as 'any' in .then((result: any) => ...)
    - Database is already configured - no setup needed
    
    Format the output as a complete TypeScript file that can be directly saved as a .ts file.
    Start with the describe() block and include all necessary code.
    Do not include markdown code fences or explanations, just the TypeScript code.
    
    APPENDED TEST REQUIREMENTS (if generating additional it() blocks):
    - Use function() syntax (not arrow functions) to access 'this' context
    - Access shared test data via this.objects_patron, this.objects_biblio, etc.
    - Do NOT call cy.task('insertSamplePatron') again - use existing data
    - Do NOT include cy.login() - it's already in the shared beforeEach
    - Example: it("should test something else", function() { const patron = this.objects_patron.patron; ... })
    PROMPT
}

sub call_openai_api {
    my ($prompt) = @_;
    
    my $api_key = $ENV{OPENAI_API_KEY};
    die "Error: OPENAI_API_KEY environment variable not set\n" unless $api_key;
    
    say colored("Using OpenAI API ($model)...", 'yellow');
    
    my $ua = LWP::UserAgent->new(timeout => 120);
    
    my $request_data = {
        model => $model,
        messages => [
            {
                role => "system",
                content => "You are an expert at writing Cypress tests for Koha, a library management system. You generate clean, working TypeScript code for Cypress tests."
            },
            {
                role => "user",
                content => $prompt
            }
        ],
        temperature => 0.3,
        max_tokens => 2000,
    };
    
    my $response = $ua->post(
        'https://api.openai.com/v1/chat/completions',
        'Content-Type' => 'application/json',
        'Authorization' => "Bearer $api_key",
        Content => encode_json($request_data)
    );
    
    if ($response->is_success) {
        my $data = decode_json($response->decoded_content);
        my $test_code = $data->{choices}[0]{message}{content};
        
        # Clean up any markdown code fences if present
        $test_code =~ s/^```typescript\s*\n//;
        $test_code =~ s/^```ts\s*\n//;
        $test_code =~ s/\n```\s*$//;
        
        return $test_code;
    } else {
        die "API Error: " . $response->status_line . "\n" . $response->decoded_content . "\n";
    }
}

sub call_github_api {
    my ($prompt) = @_;
    
    my $api_key = $ENV{GITHUB_TOKEN};
    die "Error: GITHUB_TOKEN environment variable not set\n" unless $api_key;
    
    say colored("Using GitHub Models API ($model)...", 'yellow');
    
    my $ua = LWP::UserAgent->new(timeout => 120);
    
    my $request_data = {
        model => $model,
        messages => [
            {
                role => "system",
                content => "You are an expert at writing Cypress tests for Koha, a library management system. You generate clean, working TypeScript code for Cypress tests."
            },
            {
                role => "user",
                content => $prompt
            }
        ],
        temperature => 0.3,
        max_tokens => 2000,
    };
    
    my $response = $ua->post(
        'https://models.inference.ai.azure.com/chat/completions',
        'Content-Type' => 'application/json',
        'Authorization' => "Bearer $api_key",
        Content => encode_json($request_data)
    );
    
    if ($response->is_success) {
        my $data = decode_json($response->decoded_content);
        my $test_code = $data->{choices}[0]{message}{content};
        
        # Clean up any markdown code fences if present
        $test_code =~ s/^```typescript\s*\n//;
        $test_code =~ s/^```ts\s*\n//;
        $test_code =~ s/\n```\s*$//;
        
        return $test_code;
    } else {
        die "API Error: " . $response->status_line . "\n" . $response->decoded_content . "\n";
    }
}

sub print_help {
    print <<~'HELP';
    Usage: cypress_mage.pl [OPTIONS]
    
    Generate Cypress tests from Koha bug test plans using AI
    
    Required Options:
      --bug NUMBER          Bug number (e.g., 39802)
      --test-plan FILE      Path to file containing test plan
          OR
      --text "PLAN"         Test plan as inline text
    
    Optional:
      --output FILE         Output file path (default: t/cypress/integration/Generated/Bug<NUMBER>_spec.ts)
      --provider PROVIDER   API provider: 'github' or 'openai' (default: github)
      --model MODEL         AI model to use (default: gpt-4o)
      --help               Show this help message
    
    Environment Variables:
      GITHUB_TOKEN         GitHub token (required for --provider github, default)
      OPENAI_API_KEY       OpenAI API key (required for --provider openai)
    
    Examples:
      # From file (uses GitHub Models by default)
      ./cypress_mage.pl --bug 39802 --test-plan testplan.txt
      
      # Inline test plan
      ./cypress_mage.pl --bug 39802 --text "1. Login\n2. Search patron\n3. Check logs"
      
      # Using OpenAI instead
      export OPENAI_API_KEY=sk_your_key
      ./cypress_mage.pl --bug 39802 --test-plan testplan.txt --provider openai
      
      # Custom output location
      ./cypress_mage.pl --bug 39802 --test-plan testplan.txt --output custom_test.ts
    
    HELP
}

=head1 AUTHOR

Johanna Räisä <johanna.raisa@gmail.com>
Assisted by Claude Sonnet 4.5 for code generation and optimization

=head1 LICENSE

GPL v3

=cut
