//
//  ContactViewController.swift
//  LoCo
//
//  Created by Drew McCormack on 17/01/2019.
//  Copyright © 2019 The Mental Faculty B.V. All rights reserved.
//

import UIKit
import LLVS

class ContactViewController: UIViewController {

    @IBOutlet weak var detailDescriptionLabel: UILabel?
    
    var contactBook: ContactBook?
    var contactIdentifier: Value.Identifier?
    
    @IBOutlet weak var firstNameField: UITextField!
    @IBOutlet weak var secondNameField: UITextField!
    @IBOutlet weak var streetAddressField: UITextField!
    @IBOutlet weak var postCodeField: UITextField!
    @IBOutlet weak var cityField: UITextField!
    @IBOutlet weak var countryField: UITextField!
    @IBOutlet weak var emailField: UITextField!
    @IBOutlet weak var phoneNumberField: UITextField!
    
    private var versionDidChangeObserver: AnyObject?
    
    private var contact: Contact? {
        guard let book = contactBook, let identifier = contactIdentifier else { return nil }
        return book.contacts.first(where: { $0.valueIdentifier == identifier })?.value
    }
    
    deinit {
        if let o = versionDidChangeObserver {
            NotificationCenter.default.removeObserver(o)
            versionDidChangeObserver = nil
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        versionDidChangeObserver = NotificationCenter.default.addObserver(forName: .contactBookVersionDidChange, object: contactBook, queue: nil) { notif in
            self.updateView()
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateView()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        extractContactFromView()
    }

    func showContact(at index: Int, in book: ContactBook) {
        contactBook = book
        contactIdentifier = contactBook!.contacts[index].valueIdentifier
        updateView()
    }

    func updateView() {
        guard let _ = firstNameField else { return }
        if let contact = contact {
            firstNameField.text = contact.person?.firstName
            secondNameField.text = contact.person?.secondName
            streetAddressField.text = contact.address?.streetAddress
            postCodeField.text = contact.address?.postCode
            cityField.text = contact.address?.city
            countryField.text = contact.address?.country
            emailField.text = contact.email
            phoneNumberField.text = contact.phoneNumber
        } else {
            firstNameField.text = nil
            secondNameField.text = nil
            streetAddressField.text = nil
            postCodeField.text = nil
            cityField.text = nil
            countryField.text = nil
            emailField.text = nil
            phoneNumberField.text = nil
        }
    }
    
    func extractContactFromView() {
        guard let _ = firstNameField, let contact = contact else { return }
        
        var newContact = contact
        
        let firstName = firstNameField.text
        let secondName = secondNameField.text
        let person = firstName.flatMap { Person(firstName: $0, secondName: secondName) }
        newContact.person = person
        
        let streetAddress = streetAddressField.text
        let postCode = postCodeField.text
        let city = cityField.text
        let country = countryField.text
        let address = streetAddress.flatMap {
            Address(streetAddress: $0, postCode: postCode, city: city, country: country)
        }
        newContact.address = address
        
        newContact.email = emailField.text
        newContact.phoneNumber = phoneNumberField.text
        
        try! contactBook?.update(newContact)
    }
}
