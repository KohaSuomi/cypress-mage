describe("Bug 20956: Member Flags - Set Catalogue Permission", () => {
    beforeEach(() => {
        cy.login();
        cy.title().should("eq", "Koha staff interface");
        cy.task("insertSamplePatron").then((objects_patron) => {
            cy.wrap(objects_patron).as("objects_patron");
        });
    });

    afterEach(function () {
        cy.task("deleteSampleObjects", this.objects_patron);
    });

    it("should select the catalogue permission checkbox and save", function () {
        const patron = this.objects_patron.patron;

        // Step 1: Go to the member-flags page for the created patron
        cy.visit(`/cgi-bin/koha/members/member-flags.pl?member=${patron.patron_id}`);

        // Step 2: Select the checkbox inside parent-flag-catalogue
        cy.get("#parent-flag-catalogue input[type='checkbox']").should("exist").check();

        // Step 3: Click the Save button
        cy.get("#permissions_toolbar button[type='submit']").should("exist").click();
    });


  it('should verify the info column has value {catalogue: 1}', function() {
    const patron = this.objects_patron.patron;

    // Step 4: Navigate to the log viewer page for the specific patron and module
    cy.visit(`/cgi-bin/koha/tools/viewlog.pl?do_it=1&modules=MEMBERS&object=${patron.patron_id}&src=circ`);

    // Step 5: Find the table #logst from viewlog.tt
    cy.get('#logst', { timeout: 10000 }).should('be.visible');

    // Step 6: Verify that the info column has value {catalogue: 1}
    cy.get('#logst tbody tr').each(($row) => {
        cy.wrap($row).find('td').eq(3).then(($infoColumn) => {
            const infoText = $infoColumn.text().trim();
            if (infoText.includes('{catalogue: 1}')) {
                expect(infoText).to.contain('{catalogue: 1}');
            }
        });
    });
});
});

// Created-by: AI-generated test using github API with model gpt-4o
