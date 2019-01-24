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

    @IBOutlet weak var detailDescriptionLabel: UILabel!
    
    private(set) var contactBook: ContactBook?
    private(set) var contactIdentifier: Value.Identifier?
    
    private var versionDidChangeObserver: AnyObject?
    
    private var contact: Contact? {
        guard let book = contactBook, let identifier = contactIdentifier else { return nil }
        return book.contacts.first(where: { $0.valueIdentifier == identifier })!.value
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
        updateView()
    }

    func showContact(at index: Int, in book: ContactBook) {
        contactBook = book
        contactIdentifier = contactBook!.contacts[index].valueIdentifier
        updateView()
    }

    func updateView() {
        if let contact = contact {
            detailDescriptionLabel.text = "\(contact)"
        } else {
            detailDescriptionLabel.text = "No Selection"
        }
    }
}

