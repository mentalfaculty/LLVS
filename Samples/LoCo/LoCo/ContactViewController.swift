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
            firstNameField.text = contact.person?.firstName ?? ""
            secondNameField.text = contact.person?.secondName ?? ""
        } else {
            firstNameField.text = nil
            secondNameField.text = nil
        }
    }
    
    func extractContactFromView() {
        guard let _ = firstNameField, let contact = contact else { return }
        
        var newContact = contact
        
        let firstName = firstNameField.text ?? ""
        let secondName = secondNameField.text ?? ""
        if !firstName.isEmpty || !secondName.isEmpty {
            let person = Person(firstName: firstName, secondName: (!secondName.isEmpty ? secondName : nil))
            newContact.person = person
        } else {
            newContact.person = nil
        }
        
        try? contactBook?.update(newContact)
    }
}

